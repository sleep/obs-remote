import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO

/// Orchestrates the full capture pipeline: device -> preview + encoder -> replay buffer / recorder.
public final class CaptureEngine: NSObject {

    public let captureSession = AVCaptureSession()
    public let encoder: HardwareEncoder
    public let replayBuffer: ReplayBuffer
    public let recorder = Recorder()

    private(set) public var latestPixelBuffer: CVPixelBuffer?
    private let latestFrameLock = NSLock()

    // Live FPS tracking
    private var frameCount: Int = 0
    private var dropCount: Int = 0
    private var fpsLock = NSLock()
    private(set) public var liveFPS: Double = 0
    private(set) public var droppedFrames: Int = 0

    /// Called on the 1s timer to snapshot the frame/drop counters.
    public func sampleFPS() {
        fpsLock.lock()
        liveFPS = Double(frameCount)
        droppedFrames = dropCount
        frameCount = 0
        dropCount = 0
        fpsLock.unlock()
    }

    public var onStateChange: (() -> Void)?

    private let captureQueue = DispatchQueue(label: "capture.output", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var isRunning = false
    private var recordingFormatDesc: CMFormatDescription?

    public init(replayDuration: Double = 30, bitrateMbps: Int = 20) {
        self.encoder = HardwareEncoder(bitrateMbps: bitrateMbps)
        self.replayBuffer = ReplayBuffer(duration: replayDuration)
        super.init()

        encoder.onEncodedFrame = { [weak self] frame in
            self?.handleEncodedFrame(frame)
        }
    }

    // MARK: - Replay buffer config

    /// Update replay buffer limits at runtime.
    public func updateReplayLimits(duration: Double? = nil, maxBytes: Int? = nil) {
        replayBuffer.updateLimits(duration: duration, maxBytes: maxBytes)
    }

    // MARK: - Setup & Start

    /// Start capture with auto-detected Elgato device.
    public func start() throws {
        guard let device = DeviceDiscovery.findElgato() else {
            throw CaptureError.noDeviceFound
        }
        try start(with: device)
    }

    /// Start capture with a specific device.
    public func start(with device: AVCaptureDevice) throws {
        // Check camera permission
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard authStatus == .authorized else {
            print("[Capture] Camera access status: \(authStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
            throw CaptureError.cameraAccessDenied
        }

        // Stop any existing session
        if isRunning { stop() }

        self.device = device
        print("[Capture] Using device: \(device.localizedName)")
        print("[Capture] Device formats count: \(device.formats.count)")

        // For capture cards like Cam Link 4K, the device reflects the HDMI input
        // signal — trying to switch formats can fail. Prefer the device's current
        // active format, then fall back to bestFormat scoring.
        let format: AVCaptureDevice.Format
        let targetFPS: Double

        let activeRanges = device.activeFormat.videoSupportedFrameRateRanges
        let activeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let activeMaxFPS = activeRanges.map(\.maxFrameRate).max() ?? 0

        print("[Capture] Active format: \(activeDims.width)x\(activeDims.height), fps ranges: \(activeRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" })")

        if activeDims.width >= 640 && activeMaxFPS >= 1.0 {
            // Device already has a usable active format — use it directly
            // This is critical for capture cards that mirror HDMI input
            format = device.activeFormat
            targetFPS = min(activeMaxFPS, 60)
            print("[Capture] Using device's active format directly")
        } else if let (bestFormat, bestRange) = DeviceDiscovery.bestFormat(for: device) {
            format = bestFormat
            targetFPS = min(bestRange.maxFrameRate, 60)
            print("[Capture] Using best scored format")
        } else if !device.formats.isEmpty {
            format = device.activeFormat
            targetFPS = activeMaxFPS > 0 ? min(activeMaxFPS, 60) : 30
            print("[Capture] Using device's active format as last resort")
        } else {
            print("[Capture] No formats available. All formats for \(device.localizedName):")
            DeviceDiscovery.printDevices()
            throw CaptureError.noSupportedFormat
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let timescale = CMTimeScale(max(targetFPS, 1))

        print("[Capture] Configuring: \(dims.width)x\(dims.height) @ \(Int(targetFPS))fps (timescale=\(timescale))")

        // Only change format/fps if we picked something different from active
        let needsFormatChange = format !== device.activeFormat
        print("[Capture] Format change needed: \(needsFormatChange)")

        // Configure device — capture cards like Cam Link 4K mirror the HDMI input
        // signal, so setting frame duration hangs forever. Only configure if we're
        // actually changing the format.
        if needsFormatChange {
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

        print("[Capture] Format: \(dims.width)x\(dims.height) @ \(Int(targetFPS))fps")

        captureSession.beginConfiguration()

        // Remove existing inputs/outputs
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw CaptureError.captureSessionFailed("Cannot add device input")
        }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Let AVFoundation pick the best pixel format for this device
        // instead of forcing NV12 which some devices don't support
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            throw CaptureError.captureSessionFailed("Cannot add video output")
        }
        captureSession.addOutput(output)

        captureSession.commitConfiguration()
        print("[Capture] Session configured, starting encoder...")

        // Start encoder with actual dimensions
        encoder.updateDimensions(width: dims.width, height: dims.height, fps: Int(targetFPS))
        try encoder.start()

        print("[Capture] Starting capture session...")
        captureSession.startRunning()
        isRunning = true
        print("[Capture] Pipeline running")
    }

    public func stop() {
        captureSession.stopRunning()
        encoder.stop()
        isRunning = false
    }

    // MARK: - Actions

    public func toggleRecording() {
        if recorder.isRecording {
            let onChange = onStateChange
            Task.detached {
                _ = await self.recorder.stopRecording()
                await MainActor.run { onChange?() }
            }
        } else {
            do {
                try recorder.startRecording()
                recordingFormatDesc = nil
                DispatchQueue.main.async { self.onStateChange?() }
            } catch {
                print("[Capture] Failed to start recording: \(error)")
            }
        }
    }

    public func saveReplay(lastSeconds: Double? = nil) {
        let frames = replayBuffer.getReplayFrames(lastSeconds: lastSeconds)
        guard !frames.isEmpty else {
            print("[Capture] Replay buffer is empty, nothing to save")
            return
        }

        let stats = replayBuffer.stats
        let filename = Recorder.timestampedFilename(prefix: "replay", ext: "mp4")
        let url = Recorder.defaultOutputDir().appendingPathComponent(filename)

        print("[Capture] Saving replay (\(String(format: "%.1f", stats.duration))s, \(frames.count) frames)...")

        // Write on a background task so we don't block the main thread
        let onChange = onStateChange
        Task.detached {
            let success = await Recorder.writeFrames(frames, to: url)
            if success {
                print("[Capture] Replay saved: \(url.path)")
            } else {
                print("[Capture] Failed to save replay")
            }
            await MainActor.run { onChange?() }
        }
    }

    public func takeScreenshot() {
        latestFrameLock.lock()
        let pixelBuffer = latestPixelBuffer
        latestFrameLock.unlock()

        guard let pixelBuffer else {
            print("[Capture] No frame available for screenshot")
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("[Capture] Failed to create image from frame")
            return
        }

        let filename = Recorder.timestampedFilename(prefix: "screenshot", ext: "png")
        let url = Recorder.defaultOutputDir().appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            print("[Capture] Failed to create output directory: \(error)")
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            print("[Capture] Failed to create image destination")
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        print("[Capture] Screenshot saved: \(url.path)")
    }

    // MARK: - Private

    private func handleEncodedFrame(_ frame: EncodedFrame) {
        replayBuffer.append(frame)

        if recorder.isRecording {
            if frame.isKeyframe, recordingFormatDesc == nil, let ps = frame.parameterSets {
                recordingFormatDesc = makeFormatDescription(parameterSets: ps)
            }
            if let fmt = recordingFormatDesc,
               let sb = makeSampleBuffer(from: frame, formatDescription: fmt) {
                recorder.appendFrame(sb)
            }
        }
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

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        fpsLock.lock()
        frameCount += 1
        fpsLock.unlock()

        latestFrameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameLock.unlock()

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
}
