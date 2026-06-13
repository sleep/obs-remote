import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import Metal
import Darwin

/// Orchestrates the full capture pipeline: device -> preview + encoder -> replay buffer / recorder.
public final class CaptureEngine: NSObject {

    public let captureSession = AVCaptureSession()
    public let encoder: HardwareEncoder
    public let replayBuffer: ReplayBuffer
    public private(set) var recorder: Recorder

    private(set) public var latestPixelBuffer: CVPixelBuffer?
    private let latestFrameLock = NSLock()
    private let thumbnailContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Visual effects (bake CIFilters into the captured buffer)

    /// CIFilter chain to bake into the captured buffer before encode + display.
    /// Empty array = pass-through (no per-frame CI work). Guarded by `effectsLock`.
    private var effectsFilters: [CIFilter] = []
    private let effectsLock = NSLock()

    /// Lazily-created Metal-backed CIContext used to render the filter chain.
    private lazy var effectsContext: CIContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .priorityRequestLow: false,
        ])
    }()

    /// Pool of BGRA pixel buffers recycled across frames so we don't allocate
    /// 1080p surfaces 60 times per second.
    private var effectsPool: CVPixelBufferPool?
    private var effectsPoolDims: (Int, Int) = (0, 0)

    /// Replace the active filter chain. Pass an empty array to disable the
    /// effects pipeline entirely (the capture queue then takes the fast path).
    /// Safe to call from any thread.
    public func setVisualEffectFilters(_ filters: [CIFilter]) {
        effectsLock.lock()
        effectsFilters = filters
        effectsLock.unlock()
    }

    // Live FPS tracking
    private var frameCount: Int = 0
    private var dropCount: Int = 0
    private var fpsLock = NSLock()
    private(set) public var liveFPS: Double = 0
    private(set) public var droppedFrames: Int = 0

    // Live bitrate tracking — rolling 3s window for stable readout
    private var encodedBytesTotal: Int64 = 0
    private var bitrateSnapshots: [(time: CFAbsoluteTime, bytes: Int64)] = []
    private(set) public var liveBitrateMbps: Double = 0

    /// Called on the 1s timer to snapshot the frame/drop counters.
    public func sampleFPS() {
        fpsLock.lock()
        liveFPS = Double(frameCount)
        droppedFrames = dropCount
        frameCount = 0
        dropCount = 0
        fpsLock.unlock()
    }

    /// Compute live bitrate as a rolling average over ~3 seconds.
    public func sampleBitrate() {
        let now = CFAbsoluteTimeGetCurrent()
        fpsLock.lock()
        let totalBytes = encodedBytesTotal
        fpsLock.unlock()

        bitrateSnapshots.append((now, totalBytes))
        bitrateSnapshots.removeAll { now - $0.time > 3.0 }

        if let first = bitrateSnapshots.first, bitrateSnapshots.count >= 2 {
            let elapsed = now - first.time
            if elapsed > 0.5 {
                liveBitrateMbps = Double(totalBytes - first.bytes) * 8.0 / elapsed / 1_000_000.0
            }
        }
    }

    // MARK: - Audio metering

    private let audioQueue = DispatchQueue(label: "capture.audio", qos: .userInteractive)
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let audioLock = NSLock()
    private var currentRMS: Float = 0
    private var currentPeak: Float = 0
    private var maxRMSSinceLastSample: Float = 0
    private var maxPeakSinceLastSample: Float = 0

    /// Whether the capture session has an active audio input.
    private(set) public var hasAudioInput = false

    // MARK: - Audio passthrough

    private var passthroughEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var passthroughFormat: AVAudioFormat?
    private(set) public var isPassthroughEnabled = false
    private var audioFormatDesc: CMFormatDescription?

    /// Snapshot the audio levels accumulated since the last call and reset the accumulators.
    /// Returns levels in linear scale (0.0 … 1.0).
    public func sampleAudioLevels() -> (rms: Float, peak: Float) {
        audioLock.lock()
        let rms = maxRMSSinceLastSample
        let peak = maxPeakSinceLastSample
        maxRMSSinceLastSample = 0
        maxPeakSinceLastSample = 0
        audioLock.unlock()
        return (rms, peak)
    }

    public var onStateChange: (() -> Void)?
    /// Called on every captured frame with the pixel buffer for display purposes.
    public var onFrameForDisplay: ((CVPixelBuffer) -> Void)?
    /// Fired on the main thread after a recording is fully finalized. URL is
    /// nil if finalization failed.
    public var onRecordingFinished: ((URL?) -> Void)?

    // Serializes replay-save attempts so rapid clicks don't pile up concurrent writers,
    // which used to stack inside AVAssetWriter and exhaust resources / hang.
    private let saveReplayLock = NSLock()
    private var isSavingReplay = false
    public var isSavingReplayInProgress: Bool {
        saveReplayLock.lock(); defer { saveReplayLock.unlock() }
        return isSavingReplay
    }

    private let captureQueue = DispatchQueue(label: "capture.output", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var isRunning = false
    private(set) public var isPreviewing = false
    // recordingFormatDesc is read from the encoder callback queue and written from both
    // there and the main thread (toggleRecording). Guard every access with this lock.
    private let recordingFormatLock = NSLock()
    private var recordingFormatDesc: CMFormatDescription?
    private var captureActivity: NSObjectProtocol?
    /// True once the first keyframe has been received after starting capture.
    /// Frames before this are discarded to avoid green artifacts from incomplete GOPs.
    private var receivedFirstKeyframe = false

    public init(replayDuration: Double = 30, bitrateMbps: Int = 20,
                codec: CaptureCodec = .h264) {
        self.encoder = HardwareEncoder(bitrateMbps: bitrateMbps, codec: codec)
        self.replayBuffer = ReplayBuffer(duration: replayDuration)
        self.recorder = Recorder()
        super.init()

        encoder.onEncodedFrame = { [weak self] frame in
            self?.handleEncodedFrame(frame)
        }
    }

    /// Update the encoder's target bitrate at runtime.
    public func updateBitrate(mbps: Int) {
        encoder.updateBitrate(mbps: mbps)
    }

    /// Currently configured output codec.
    public var codec: CaptureCodec { encoder.codec }

    /// Switch the output codec. If capture is active the encoder is restarted
    /// in place; otherwise the codec is staged for the next start. Always
    /// clears the replay buffer because mixed-codec frames can't be muxed
    /// into one output file. If recording is active, the current file is
    /// finalized cleanly before the codec swap — the writer was configured
    /// for the old codec and would be left without a moov atom otherwise.
    public func setCodec(_ newCodec: CaptureCodec) async {
        guard newCodec != encoder.codec else { return }
        let wasRunning = isRunning
        if wasRunning {
            encoder.stop()
        }
        if recorder.isRecording {
            _ = await recorder.stopRecording()
            DispatchQueue.main.async { self.onStateChange?() }
        }
        encoder.setCodec(newCodec)
        replayBuffer.clear()
        recordingFormatLock.lock()
        recordingFormatDesc = nil
        recordingFormatLock.unlock()
        receivedFirstKeyframe = false
        if wasRunning {
            do {
                try encoder.start()
            } catch {
                print("[Capture] Encoder restart after codec change failed: \(error)")
            }
        }
        print("[Capture] Codec set to \(newCodec.displayName)")
    }

    // MARK: - Replay buffer config

    /// Update replay buffer limits at runtime.
    public func updateReplayLimits(duration: Double? = nil, maxBytes: Int? = nil) {
        replayBuffer.updateLimits(duration: duration, maxBytes: maxBytes)
    }

    /// Replace the recorder with one pointing at a new output directory.
    /// Only allowed when not actively recording.
    public func setOutputDirectory(_ url: URL) {
        guard !recorder.isRecording else { return }
        recorder = Recorder(outputDir: url)
    }

    // MARK: - Setup & Start

    /// Start capture with auto-detected Elgato device.
    public func start() throws {
        guard let device = DeviceDiscovery.findElgato() else {
            throw CaptureError.noDeviceFound
        }
        try start(with: device)
    }

    /// Resolve the best format & FPS for a device. Shared by preview and full capture.
    private func resolveFormat(for device: AVCaptureDevice) throws -> (AVCaptureDevice.Format, Double) {
        let activeRanges = device.activeFormat.videoSupportedFrameRateRanges
        let activeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let activeMaxFPS = activeRanges.map(\.maxFrameRate).max() ?? 0

        print("[Capture] Active format: \(activeDims.width)x\(activeDims.height), fps ranges: \(activeRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" })")

        if activeDims.width >= 640 && activeMaxFPS >= 1.0 {
            print("[Capture] Using device's active format directly")
            return (device.activeFormat, min(activeMaxFPS, 60))
        } else if let (bestFormat, bestRange) = DeviceDiscovery.bestFormat(for: device) {
            print("[Capture] Using best scored format")
            return (bestFormat, min(bestRange.maxFrameRate, 60))
        } else if !device.formats.isEmpty {
            let fps = activeMaxFPS > 0 ? min(activeMaxFPS, 60) : 30.0
            print("[Capture] Using device's active format as last resort")
            return (device.activeFormat, fps)
        } else {
            print("[Capture] No formats available. All formats for \(device.localizedName):")
            DeviceDiscovery.printDevices()
            throw CaptureError.noSupportedFormat
        }
    }

    /// Configure device format if needed. Shared by preview and full capture.
    private func configureDevice(_ device: AVCaptureDevice, format: AVCaptureDevice.Format, targetFPS: Double) {
        let needsFormatChange = format !== device.activeFormat
        print("[Capture] Format change needed: \(needsFormatChange)")

        if needsFormatChange {
            let timescale = CMTimeScale(max(targetFPS, 1))
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: timescale)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: timescale)
                device.unlockForConfiguration()
            } catch {
                print("[Capture] lockForConfiguration failed: \(error) — proceeding with current config")
            }
        } else {
            print("[Capture] Skipping device config (already using active format)")
        }
    }

    // MARK: - Audio setup

    /// Set the audio input device explicitly. Pass nil to remove audio input.
    /// Can be called at any time — the capture session is reconfigured in place.
    /// Returns true if both an audio input and output were successfully wired up.
    @discardableResult
    public func setAudioInputDevice(_ device: AVCaptureDevice?) -> Bool {
        captureSession.beginConfiguration()
        removeAudioOutput()
        defer { captureSession.commitConfiguration() }

        guard let device else { return false }

        // Add the input first. If this fails (e.g. stale device reference after a
        // USB unplug/replug), bail out entirely — adding an audio data output
        // without an input would just sit there delivering nothing while the UI
        // happily reported "audio active". That's the bug that made the meters
        // freeze + the saved replay go silent after reconnect.
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            print("[Capture] Could not create audio input for \(device.localizedName): \(error)")
            return false
        }
        guard captureSession.canAddInput(input) else {
            print("[Capture] Session refused audio input for \(device.localizedName)")
            return false
        }
        captureSession.addInput(input)
        audioDeviceInput = input

        let output = AVCaptureAudioDataOutput()
        // Force Float32 interleaved so metering + passthrough get a known format
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard captureSession.canAddOutput(output) else {
            print("[Capture] Could not add audio output for \(device.localizedName) — removing the input we just added")
            captureSession.removeInput(input)
            audioDeviceInput = nil
            return false
        }
        captureSession.addOutput(output)
        audioOutput = output
        hasAudioInput = true
        print("[Capture] Audio input set: \(device.localizedName)")
        return true
    }

    /// Remove audio output and any separate audio device input from the session.
    /// Must be called within beginConfiguration/commitConfiguration.
    private func removeAudioOutput() {
        if let output = audioOutput {
            captureSession.removeOutput(output)
            audioOutput = nil
        }
        if let input = audioDeviceInput {
            captureSession.removeInput(input)
            audioDeviceInput = nil
        }
        hasAudioInput = false
        // Clear cached format so the next device's format is picked up on its first buffer.
        // Without this, swapping audio devices leaves the recorder + replay writer hinted
        // at the OLD format (sample rate / channel count), causing append failures.
        audioFormatDesc = nil
        // Tear down the passthrough engine — it was configured for the previous device's
        // sample rate / channel count and would mis-play buffers in a different layout.
        // Leave `isPassthroughEnabled` set so the engine re-initializes lazily on the
        // first buffer from the new device.
        resetPassthroughEngine()
        audioLock.lock()
        currentRMS = 0
        currentPeak = 0
        maxRMSSinceLastSample = 0
        maxPeakSinceLastSample = 0
        audioLock.unlock()
    }

    /// Start playing captured audio through the default system output.
    public func startPassthrough() {
        guard !isPassthroughEnabled else { return }
        isPassthroughEnabled = true
        // Engine + player are lazily configured on first audio buffer
        // (we need the sample rate from the format description)
        print("[Capture] Audio passthrough enabled")
    }

    /// Stop audio passthrough playback.
    public func stopPassthrough() {
        isPassthroughEnabled = false
        tearDownPassthroughEngine()
        print("[Capture] Audio passthrough disabled")
    }

    /// Tear down the passthrough engine without changing `isPassthroughEnabled` —
    /// used when the audio device changes so the engine re-initializes lazily for
    /// the new device's sample rate / channel count.
    private func resetPassthroughEngine() {
        guard passthroughEngine != nil else { return }
        tearDownPassthroughEngine()
    }

    private func tearDownPassthroughEngine() {
        playerNode?.stop()
        if let engine = passthroughEngine, engine.isRunning {
            engine.stop()
        }
        if let node = playerNode, let engine = passthroughEngine {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        passthroughEngine = nil
        playerNode = nil
        passthroughFormat = nil
    }

    // MARK: - Preview (lightweight, no encoder)

    /// Start a preview-only session: adds device input and runs the session so
    /// AVCaptureVideoPreviewLayer shows live video, but does NOT start the encoder
    /// or video data output.
    public func startPreview(with device: AVCaptureDevice) throws {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard authStatus == .authorized else {
            throw CaptureError.cameraAccessDenied
        }

        // Tear down any existing state
        if isRunning { stop() }
        if isPreviewing { stopPreview() }

        self.device = device
        print("[Preview] Starting preview for: \(device.localizedName)")

        let (format, targetFPS) = try resolveFormat(for: device)
        configureDevice(device, format: format, targetFPS: targetFPS)

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("[Preview] Format: \(dims.width)x\(dims.height) @ \(Int(targetFPS))fps")

        // Create the input first (can throw) BEFORE touching the session config
        let input = try AVCaptureDeviceInput(device: device)

        captureSession.beginConfiguration()
        for existing in captureSession.inputs { captureSession.removeInput(existing) }
        for existing in captureSession.outputs { captureSession.removeOutput(existing) }

        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw CaptureError.captureSessionFailed("Cannot add device input")
        }
        captureSession.addInput(input)
        captureSession.commitConfiguration()

        captureSession.startRunning()
        isPreviewing = true
        print("[Preview] Live preview running")
    }

    /// Stop preview-only session.
    public func stopPreview() {
        guard isPreviewing, !isRunning else { return }
        captureSession.stopRunning()
        captureSession.beginConfiguration()
        // removeAudioOutput is called within begin/commit
        removeAudioOutput()
        for input in captureSession.inputs { captureSession.removeInput(input) }
        captureSession.commitConfiguration()
        stopPassthrough()
        isPreviewing = false
        self.device = nil
        print("[Preview] Stopped")
    }

    // MARK: - Full capture (encoder + replay buffer)

    /// Start full capture with a specific device. If already previewing the same
    /// device, upgrades the session in-place by adding the video data output and
    /// starting the encoder — no visible glitch in the preview.
    public func start(with device: AVCaptureDevice) throws {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard authStatus == .authorized else {
            print("[Capture] Camera access status: \(authStatus.rawValue)")
            throw CaptureError.cameraAccessDenied
        }

        if isRunning { stop() }

        let alreadyPreviewing = isPreviewing && self.device?.uniqueID == device.uniqueID

        if !alreadyPreviewing {
            // Need full setup from scratch
            if isPreviewing { stopPreview() }

            self.device = device
            print("[Capture] Using device: \(device.localizedName)")

            let (format, targetFPS) = try resolveFormat(for: device)
            configureDevice(device, format: format, targetFPS: targetFPS)

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("[Capture] Format: \(dims.width)x\(dims.height) @ \(Int(targetFPS))fps")

            // Create input before touching session config — AVCaptureDeviceInput(device:) can throw
            let input = try AVCaptureDeviceInput(device: device)

            captureSession.beginConfiguration()
            for existing in captureSession.inputs { captureSession.removeInput(existing) }
            for existing in captureSession.outputs { captureSession.removeOutput(existing) }

            guard captureSession.canAddInput(input) else {
                captureSession.commitConfiguration()
                throw CaptureError.captureSessionFailed("Cannot add device input")
            }
            captureSession.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                throw CaptureError.captureSessionFailed("Cannot add video output")
            }
            captureSession.addOutput(output)
            captureSession.commitConfiguration()

            encoder.updateDimensions(width: dims.width, height: dims.height, fps: Int(targetFPS))
            try encoder.start()

            captureSession.startRunning()
        } else {
            // Upgrade from preview: add output + encoder while session is running
            print("[Capture] Upgrading preview to full capture")

            let (format, targetFPS) = try resolveFormat(for: device)
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            captureSession.beginConfiguration()
            // Remove only non-audio outputs; keep audio if already set up from preview
            for output in captureSession.outputs where !(output is AVCaptureAudioDataOutput) {
                captureSession.removeOutput(output)
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                throw CaptureError.captureSessionFailed("Cannot add video output")
            }
            captureSession.addOutput(output)
            captureSession.commitConfiguration()

            encoder.updateDimensions(width: dims.width, height: dims.height, fps: Int(targetFPS))
            try encoder.start()
        }

        isPreviewing = false
        isRunning = true
        receivedFirstKeyframe = false

        // Prevent macOS from throttling this process when backgrounded.
        // Without this, AVCaptureSession stops delivering frames to non-frontmost apps.
        if captureActivity == nil {
            captureActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Video capture pipeline active"
            )
        }

        print("[Capture] Pipeline running")
    }

    /// Stop the full capture pipeline. If the device is still available, falls back
    /// to preview-only mode so the user keeps seeing the video feed.
    public func stop() {
        if let activity = captureActivity {
            ProcessInfo.processInfo.endActivity(activity)
            captureActivity = nil
        }

        let wasDevice = device
        encoder.stop()

        // Remove video data output but keep inputs + audio output for preview
        captureSession.beginConfiguration()
        for output in captureSession.outputs where !(output is AVCaptureAudioDataOutput) {
            captureSession.removeOutput(output)
        }
        captureSession.commitConfiguration()

        isRunning = false

        // Fall back to preview if we still have a device input
        if wasDevice != nil && !captureSession.inputs.isEmpty {
            isPreviewing = true
            // Session is still running — preview layer continues to show video
            print("[Capture] Stopped capture, fell back to preview")
        } else {
            captureSession.stopRunning()
            isPreviewing = false
            print("[Capture] Stopped capture and preview")
        }
    }

    // MARK: - Actions

    public func toggleRecording() {
        if recorder.isRecording {
            let onChange = onStateChange
            let onFinished = onRecordingFinished
            Task.detached {
                let url = await self.recorder.stopRecording()
                // Clear the format hint so the next recording session derives its own
                // from the replay buffer / first keyframe (covers device or resolution
                // changes between sessions).
                self.recordingFormatLock.lock()
                self.recordingFormatDesc = nil
                self.recordingFormatLock.unlock()
                await MainActor.run {
                    onChange?()
                    onFinished?(url)
                }
            }
        } else {
            do {
                // Build format description from replay buffer so AVAssetWriterInput
                // gets the required sourceFormatHint for passthrough writing.
                // ProRes frames carry their own format description; H.264 requires
                // reconstructing one from the SPS/PPS parameter sets.
                let frames = replayBuffer.getReplayFrames(lastSeconds: 1)
                let formatHint: CMFormatDescription?
                if let keyframe = frames.first(where: { $0.isKeyframe }) {
                    if let fd = keyframe.formatDescription {
                        formatHint = fd
                    } else if let ps = keyframe.parameterSets {
                        formatHint = makeFormatDescription(parameterSets: ps)
                    } else {
                        formatHint = nil
                    }
                } else {
                    formatHint = nil
                }
                recordingFormatLock.lock()
                recordingFormatDesc = formatHint
                recordingFormatLock.unlock()
                try recorder.startRecording(codec: codec,
                                            sourceFormatHint: formatHint,
                                            audioFormatHint: audioFormatDesc)
                DispatchQueue.main.async { self.onStateChange?() }
            } catch {
                print("[Capture] Failed to start recording: \(error)")
            }
        }
    }

    public func saveReplay(lastSeconds: Double? = nil, completion: ((URL?) -> Void)? = nil) {
        saveReplayLock.lock()
        if isSavingReplay {
            saveReplayLock.unlock()
            print("[Capture] Replay save already in progress — ignoring duplicate request")
            DispatchQueue.main.async { completion?(nil) }
            return
        }
        isSavingReplay = true
        saveReplayLock.unlock()

        let replayData = replayBuffer.getReplayData(lastSeconds: lastSeconds)
        guard !replayData.video.isEmpty else {
            print("[Capture] Replay buffer is empty, nothing to save")
            saveReplayLock.lock(); isSavingReplay = false; saveReplayLock.unlock()
            DispatchQueue.main.async { completion?(nil) }
            return
        }

        let stats = replayBuffer.stats
        let activeCodec = codec
        let filename = Recorder.timestampedFilename(prefix: "replay", ext: activeCodec.fileExtension)
        let url = recorder.outputDir.appendingPathComponent(filename)

        print("[Capture] Saving replay (\(String(format: "%.1f", stats.duration))s, \(replayData.video.count) frames, \(replayData.audio.count) audio samples)...")

        // Write on a background task so we don't block the main thread
        let onChange = onStateChange
        Task.detached { [weak self] in
            let success = await Recorder.writeFrames(replayData.video, audioSamples: replayData.audio,
                                                     to: url, fileType: activeCodec.fileType)
            if success {
                print("[Capture] Replay saved: \(url.path)")
            } else {
                print("[Capture] Failed to save replay")
            }
            await MainActor.run {
                self?.clearSavingReplayFlag()
                onChange?()
                completion?(success ? url : nil)
            }
        }
    }

    private func clearSavingReplayFlag() {
        saveReplayLock.lock()
        isSavingReplay = false
        saveReplayLock.unlock()
    }

    @discardableResult
    public func takeScreenshot() -> URL? {
        latestFrameLock.lock()
        let pixelBuffer = latestPixelBuffer
        latestFrameLock.unlock()

        guard let pixelBuffer else {
            print("[Capture] No frame available for screenshot")
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("[Capture] Failed to create image from frame")
            return nil
        }

        let filename = Recorder.timestampedFilename(prefix: "screenshot", ext: "png")
        let url = recorder.outputDir.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            print("[Capture] Failed to create output directory: \(error)")
            return nil
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            print("[Capture] Failed to create image destination")
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            print("[Capture] Failed to finalize screenshot")
            return nil
        }
        print("[Capture] Screenshot saved: \(url.path)")
        return url
    }

    /// Create a small thumbnail CGImage from the latest captured frame.
    /// Thread-safe — designed to be called from a background queue.
    public func createThumbnail(maxWidth: CGFloat = 160) -> CGImage? {
        latestFrameLock.lock()
        let pb = latestPixelBuffer
        latestFrameLock.unlock()
        guard let pb else { return nil }

        let ci = CIImage(cvPixelBuffer: pb)
        let scale = maxWidth / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return thumbnailContext.createCGImage(scaled, from: scaled.extent)
    }

    // MARK: - Private

    private func handleEncodedFrame(_ frame: EncodedFrame) {
        // Wait for the first keyframe before buffering — frames before the first
        // keyframe lack parameter sets and produce green/corrupt artifacts.
        if !receivedFirstKeyframe {
            guard frame.isKeyframe else { return }
            receivedFirstKeyframe = true
        }

        fpsLock.lock()
        encodedBytesTotal += Int64(frame.size)
        fpsLock.unlock()

        replayBuffer.append(frame)

        if recorder.isRecording {
            recordingFormatLock.lock()
            if recordingFormatDesc == nil {
                if let fd = frame.formatDescription {
                    // ProRes — format description is intrinsic to every frame.
                    recordingFormatDesc = fd
                } else if frame.isKeyframe, let ps = frame.parameterSets {
                    // H.264 — reconstruct from SPS/PPS in this keyframe.
                    recordingFormatDesc = makeFormatDescription(parameterSets: ps)
                }
            }
            let fmt = recordingFormatDesc
            recordingFormatLock.unlock()
            if let fmt, let sb = makeSampleBuffer(from: frame, formatDescription: fmt) {
                recorder.appendFrame(sb)
            }
        }
    }

    // MARK: - Effects rendering

    /// Take a snapshot of the current filter chain. Returns nil when no effects
    /// are configured so callers can take the fast pass-through path.
    private func snapshotEffectsFilters() -> [CIFilter]? {
        effectsLock.lock()
        let filters = effectsFilters
        effectsLock.unlock()
        return filters.isEmpty ? nil : filters
    }

    /// Render the filter chain over `source` into a recycled BGRA buffer.
    /// Returns nil on failure — callers fall back to the unfiltered buffer so a
    /// transient CI error never blanks the recording.
    private func renderFilteredFrame(_ source: CVPixelBuffer, with filters: [CIFilter]) -> CVPixelBuffer? {
        guard let context = effectsContext else { return nil }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if effectsPool == nil || effectsPoolDims != (width, height) {
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            let bufferAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttrs as CFDictionary,
                bufferAttrs as CFDictionary,
                &pool
            )
            guard status == kCVReturnSuccess, let pool else { return nil }
            effectsPool = pool
            effectsPoolDims = (width, height)
        }
        guard let pool = effectsPool else { return nil }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let outBuffer = destination else {
            return nil
        }

        var ci = CIImage(cvPixelBuffer: source)
        for filter in filters {
            filter.setValue(ci, forKey: kCIInputImageKey)
            guard let output = filter.outputImage else { return nil }
            ci = output
        }

        // Render in-place. Use the source's color space so colors round-trip
        // sensibly through the BGRA intermediate.
        let colorSpace = CVImageBufferGetColorSpace(source)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        context.render(ci, to: outBuffer, bounds: ci.extent, colorSpace: colorSpace)
        return outBuffer
    }

    private func makeFormatDescription(parameterSets psData: Data) -> CMFormatDescription? {
        let bytes = [UInt8](psData)
        var naluStarts: [Int] = []
        for i in 0..<bytes.count - 3 {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                naluStarts.append(i + 4)
            }
        }

        var paramSets: [Data] = []
        for (idx, start) in naluStarts.enumerated() {
            let end = idx + 1 < naluStarts.count ? naluStarts[idx + 1] - 4 : bytes.count
            paramSets.append(Data(bytes[start..<end]))
        }
        guard paramSets.count >= 2 else { return nil }

        var formatDesc: CMFormatDescription?
        let pointers = paramSets.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = paramSets.map { $0.count }

        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc
        )
        return status == noErr ? formatDesc : nil
    }

    private func makeSampleBuffer(from frame: EncodedFrame,
                                   formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let data = frame.data

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: ptr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: frame.pts,
            decodeTimeStamp: frame.dts
        )
        var size = data.count

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )

        return status == noErr ? sampleBuffer : nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate + Audio

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        // Audio path
        if output is AVCaptureAudioDataOutput {
            processAudioSampleBuffer(sampleBuffer)
            return
        }

        // Video path — keep thread at max priority
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

        guard let rawPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        fpsLock.lock()
        frameCount += 1
        fpsLock.unlock()

        // Bake visual effects into the buffer on the capture queue so the same
        // filtered frame reaches the display, the encoder, the replay buffer,
        // and any screenshot — they all stay in sync. Falls back to the raw
        // buffer on render failure so we never drop a frame.
        let pixelBuffer: CVPixelBuffer
        if let filters = snapshotEffectsFilters(),
           let rendered = renderFilteredFrame(rawPixelBuffer, with: filters) {
            pixelBuffer = rendered
        } else {
            pixelBuffer = rawPixelBuffer
        }

        latestFrameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameLock.unlock()

        // Only display after the first keyframe to avoid green artifacts
        if receivedFirstKeyframe {
            onFrameForDisplay?(pixelBuffer)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        encoder.encode(pixelBuffer, presentationTime: pts, duration: duration)
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        fpsLock.lock()
        dropCount += 1
        fpsLock.unlock()
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer
        )
        guard status == noErr, let ptr = dataPointer, length > 0 else { return }

        let sampleCount = length / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return }

        let floatPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float32.self)

        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<sampleCount {
            let s = abs(floatPtr[i])
            sumSquares += s * s
            if s > peak { peak = s }
        }

        let rms = sqrt(sumSquares / Float(sampleCount))

        audioLock.lock()
        currentRMS = rms
        currentPeak = peak
        if rms > maxRMSSinceLastSample { maxRMSSinceLastSample = rms }
        if peak > maxPeakSinceLastSample { maxPeakSinceLastSample = peak }
        audioLock.unlock()

        // Audio passthrough
        if isPassthroughEnabled {
            forwardToPassthrough(sampleBuffer, floatData: floatPtr, sampleCount: sampleCount)
        }

        // Store audio in replay buffer
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if audioFormatDesc == nil { audioFormatDesc = formatDesc }
            let audioData = Data(bytes: ptr, count: length)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            let sample = AudioSample(data: audioData, pts: pts, duration: duration,
                                      numSamples: numSamples, formatDescription: formatDesc)
            replayBuffer.appendAudio(sample)
        }

        // Forward to recorder for live recording
        if recorder.isRecording {
            recorder.appendAudioSample(sampleBuffer)
        }
    }

    private func forwardToPassthrough(_ sampleBuffer: CMSampleBuffer,
                                       floatData: UnsafePointer<Float32>,
                                       sampleCount: Int) {
        // Lazy engine setup on first buffer (need format info from the sample)
        if passthroughEngine == nil {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

            let channels = max(asbd.mChannelsPerFrame, 1)
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: channels,
                interleaved: false
            ) else { return }

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            do {
                try engine.start()
                player.play()
                passthroughEngine = engine
                playerNode = player
                passthroughFormat = format
                print("[Capture] Passthrough started: \(Int(asbd.mSampleRate))Hz, \(channels)ch")
            } catch {
                print("[Capture] Passthrough engine failed to start: \(error)")
                return
            }
        }

        guard let format = passthroughFormat, let player = playerNode else { return }

        let channels = Int(format.channelCount)
        let framesPerChannel = sampleCount / channels
        guard framesPerChannel > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(framesPerChannel))
        else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(framesPerChannel)

        // Source is interleaved Float32, destination is deinterleaved
        if let channelData = pcmBuffer.floatChannelData {
            if channels == 1 {
                memcpy(channelData[0], floatData, framesPerChannel * MemoryLayout<Float32>.size)
            } else {
                for sample in 0..<framesPerChannel {
                    for ch in 0..<channels {
                        channelData[ch][sample] = floatData[sample * channels + ch]
                    }
                }
            }
        }

        player.scheduleBuffer(pcmBuffer)
    }
}
