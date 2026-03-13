import AVFoundation
import CoreMedia
import CoreVideo

/// Orchestrates the full capture pipeline: device → preview + encoder → replay buffer / recorder.
final class CaptureEngine: NSObject {

    let captureSession = AVCaptureSession()
    let encoder: HardwareEncoder
    let replayBuffer: ReplayBuffer
    let recorder = Recorder()

    /// The latest raw pixel buffer, used for screenshots.
    private(set) var latestPixelBuffer: CVPixelBuffer?
    private let latestFrameLock = NSLock()

    /// Called on main thread when recording state changes.
    var onStateChange: (() -> Void)?

    private let captureQueue = DispatchQueue(label: "capture.output", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var isRunning = false

    // Passthrough format description for the recorder (built from first encoded keyframe)
    private var recordingFormatDesc: CMFormatDescription?

    init(replayDuration: Double = 30, bitrateMbps: Int = 20) {
        self.encoder = HardwareEncoder(bitrateMbps: bitrateMbps)
        self.replayBuffer = ReplayBuffer(duration: replayDuration)
        super.init()

        encoder.onEncodedFrame = { [weak self] frame in
            self?.handleEncodedFrame(frame)
        }
    }

    // MARK: - Setup & Start

    func start() throws {
        guard let device = DeviceDiscovery.findElgato() else {
            throw CaptureError.noDeviceFound
        }
        self.device = device
        print("[Capture] Using device: \(device.localizedName)")

        guard let (format, fpsRange) = DeviceDiscovery.best1080p60Format(for: device) else {
            throw CaptureError.noSupportedFormat
        }

        // Configure device
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        device.unlockForConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("[Capture] Format: \(dims.width)x\(dims.height) @ 60fps")

        // Build capture session
        captureSession.beginConfiguration()
        // Don't set a session preset — we configure activeFormat directly on the device,
        // which takes priority over any preset.

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw CaptureError.captureSessionFailed("Cannot add device input")
        }
        captureSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Request NV12 — matches hardware encoder's preferred input, avoids conversions
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard captureSession.canAddOutput(output) else {
            throw CaptureError.captureSessionFailed("Cannot add video output")
        }
        captureSession.addOutput(output)

        captureSession.commitConfiguration()

        // Start encoder
        try encoder.start()

        // Start capture
        captureSession.startRunning()
        isRunning = true
        print("[Capture] Pipeline running")
    }

    func stop() {
        captureSession.stopRunning()
        encoder.stop()
        isRunning = false
    }

    // MARK: - Actions

    func toggleRecording() {
        if recorder.isRecording {
            Task {
                let url = await recorder.stopRecording()
                DispatchQueue.main.async { self.onStateChange?() }
            }
        } else {
            do {
                try recorder.startRecording()
                recordingFormatDesc = nil // will be set on first keyframe
                DispatchQueue.main.async { self.onStateChange?() }
            } catch {
                print("[Capture] Failed to start recording: \(error)")
            }
        }
    }

    func saveReplay(lastSeconds: Double? = nil) {
        let frames = replayBuffer.getReplayFrames(lastSeconds: lastSeconds)
        guard !frames.isEmpty else {
            print("[Capture] Replay buffer is empty, nothing to save")
            return
        }

        let stats = replayBuffer.stats
        let filename = Recorder.timestampedFilename(prefix: "replay", ext: "mp4")
        let url = Recorder.defaultOutputDir().appendingPathComponent(filename)

        print("[Capture] Saving replay (\(String(format: "%.1f", stats.duration))s, \(frames.count) frames)...")

        Task {
            let success = await Recorder.writeFrames(frames, to: url)
            if success {
                print("[Capture] Replay saved: \(url.path)")
            } else {
                print("[Capture] Failed to save replay")
            }
            DispatchQueue.main.async { self.onStateChange?() }
        }
    }

    func takeScreenshot() {
        latestFrameLock.lock()
        let pixelBuffer = latestPixelBuffer
        latestFrameLock.unlock()

        guard let pixelBuffer else {
            print("[Capture] No frame available for screenshot")
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)

        guard let cgImage else {
            print("[Capture] Failed to create image from frame")
            return
        }

        let filename = Recorder.timestampedFilename(prefix: "screenshot", ext: "png")
        let url = Recorder.defaultOutputDir().appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
            print("[Capture] Screenshot saved: \(url.path)")
        } catch {
            print("[Capture] Failed to save screenshot: \(error)")
        }
    }

    // MARK: - Private

    private func handleEncodedFrame(_ frame: EncodedFrame) {
        // Always feed the replay buffer
        replayBuffer.append(frame)

        // Feed the recorder if active
        if recorder.isRecording {
            // Build a CMSampleBuffer from the encoded frame and pass to recorder
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

        var status = data.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
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
        }
        guard status == noErr, let block = blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
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

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Store latest frame for screenshots
        latestFrameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameLock.unlock()

        // Feed to hardware encoder
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        encoder.encode(pixelBuffer, presentationTime: pts, duration: duration)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Frame was dropped — this shouldn't happen often with hardware encoding on M2
        print("[Capture] Frame dropped")
    }
}
