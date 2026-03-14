@preconcurrency import AVFoundation
import CoreMedia

/// Writes encoded H.264 frames to an MP4 file using AVAssetWriter.
public final class Recorder {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isWriting = false
    private var sessionStarted = false
    public let outputDir: URL

    public init(outputDir: URL? = nil) {
        self.outputDir = outputDir ?? Recorder.defaultOutputDir()
    }

    /// Start recording to a new MP4 file. Returns the file path.
    @discardableResult
    public func startRecording(width: Int = 1920, height: Int = 1080,
                               sourceFormatHint: CMFormatDescription? = nil,
                               audioFormatHint: CMFormatDescription? = nil) throws -> URL {
        let filename = Recorder.timestampedFilename(prefix: "recording", ext: "mp4")
        let url = outputDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // nil outputSettings = passthrough (we provide already-encoded H.264 data)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: sourceFormatHint)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        // Add audio track if audio format is available
        var aInput: AVAssetWriterInput?
        if let audioFmt = audioFormatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFmt)?.pointee {
            let channels = max(Int(asbd.mChannelsPerFrame), 1)
            let sampleRate = asbd.mSampleRate
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: 128_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings,
                                         sourceFormatHint: audioFmt)
            ai.expectsMediaDataInRealTime = true
            writer.add(ai)
            aInput = ai
        }

        writer.startWriting()

        self.assetWriter = writer
        self.videoInput = input
        self.audioInput = aInput
        self.isWriting = true
        self.sessionStarted = false

        print("[Recorder] Recording to: \(url.path)")
        return url
    }

    /// Append an encoded frame to the recording.
    public func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, let input = videoInput, let writer = assetWriter else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                print("[Recorder] Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                isWriting = false
            }
            return
        }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Append an audio sample buffer to the recording.
    public func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, sessionStarted, let input = audioInput, let writer = assetWriter else { return }
        guard writer.status == .writing else { return }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Stop recording and finalize the file.
    public func stopRecording() async -> URL? {
        guard isWriting, let writer = assetWriter else { return nil }
        isWriting = false

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        let writerURL = writer.outputURL
        return await withCheckedContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    print("[Recorder] Saved: \(writerURL.path)")
                    continuation.resume(returning: writerURL)
                } else {
                    print("[Recorder] Failed to finalize: \(writer.error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Write an array of encoded frames to a new MP4 file (used for saving replays).
    public static func writeFrames(_ frames: [EncodedFrame], audioSamples: [AudioSample] = [],
                            to url: URL,
                            width: Int = 1920, height: Int = 1080) async -> Bool {
        // Drop any leading non-keyframes — the writer can't start mid-GOP
        let startIdx = frames.firstIndex(where: { $0.isKeyframe }) ?? frames.count
        let usable = Array(frames[startIdx...])
        guard !usable.isEmpty else {
            print("[Recorder] No keyframes found in \(frames.count) frames, cannot write replay")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

            guard let formatDesc = createFormatDescription(from: usable[0]) else {
                print("[Recorder] Failed to create format description")
                return false
            }

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: formatDesc)
            input.expectsMediaDataInRealTime = false
            writer.add(input)

            // Add audio track if audio samples are available
            var audioInput: AVAssetWriterInput?
            if let firstAudio = audioSamples.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(firstAudio.formatDescription)?.pointee {
                let channels = max(Int(asbd.mChannelsPerFrame), 1)
                let sampleRate = asbd.mSampleRate
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: channels,
                    AVSampleRateKey: sampleRate,
                    AVEncoderBitRateKey: 128_000,
                ]
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings,
                                             sourceFormatHint: firstAudio.formatDescription)
                ai.expectsMediaDataInRealTime = false
                writer.add(ai)
                audioInput = ai
            }

            writer.startWriting()

            let baseTime = usable[0].pts
            writer.startSession(atSourceTime: .zero)

            var written = 0
            for frame in usable {
                guard let sampleBuffer = createSampleBuffer(
                    from: frame, formatDescription: formatDesc, baseTime: baseTime
                ) else { continue }

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }

                if !input.append(sampleBuffer) {
                    print("[Recorder] Append failed at frame \(written): \(writer.error?.localizedDescription ?? "unknown")")
                    break
                }
                written += 1
            }

            // Write audio samples
            if let aInput = audioInput {
                var audioWritten = 0
                for sample in audioSamples {
                    guard let sampleBuffer = createAudioSampleBuffer(from: sample, baseTime: baseTime) else { continue }
                    while !aInput.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    if !aInput.append(sampleBuffer) {
                        print("[Recorder] Audio append failed at sample \(audioWritten): \(writer.error?.localizedDescription ?? "unknown")")
                        break
                    }
                    audioWritten += 1
                }
                aInput.markAsFinished()
                print("[Recorder] Wrote \(audioWritten) audio samples")
            }

            input.markAsFinished()

            let writerRef = writer
            return await withCheckedContinuation { continuation in
                writerRef.finishWriting {
                    let success = writerRef.status == .completed
                    if !success {
                        print("[Recorder] Replay write failed: \(writerRef.error?.localizedDescription ?? "unknown")")
                    }
                    continuation.resume(returning: success)
                }
            }

        } catch {
            print("[Recorder] Error writing replay: \(error)")
            return false
        }
    }

    public var isRecording: Bool { isWriting }

    // MARK: - Helpers

    public static func defaultOutputDir() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("ElgatoCapture")
    }

    public static func timestampedFilename(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(prefix)_\(formatter.string(from: Date())).\(ext)"
    }

    /// Create a CMFormatDescription from encoded H.264 parameter sets.
    private static func createFormatDescription(from keyframe: EncodedFrame) -> CMFormatDescription? {
        guard let paramData = keyframe.parameterSets else { return nil }

        let bytes = [UInt8](paramData)
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

        let pointers = paramSets.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = paramSets.map { $0.count }

        var formatDesc: CMFormatDescription?
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

    /// Create a CMSampleBuffer from an AudioSample for writing to AVAssetWriter.
    private static func createAudioSampleBuffer(from sample: AudioSample,
                                                 baseTime: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let data = sample.data

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
        let pts = CMTimeSubtract(sample.pts, baseTime)
        let dur = sample.duration.isValid && sample.duration.seconds > 0
            ? sample.duration
            : CMTimeMake(value: 1024, timescale: 48000)
        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        let numSamples = sample.numSamples
        guard numSamples > 0 else { return nil }
        let sampleSize = data.count / numSamples
        var sizes = [Int](repeating: sampleSize, count: numSamples)

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: sample.formatDescription,
            sampleCount: numSamples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: numSamples,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer
        )

        return status == noErr ? sampleBuffer : nil
    }

    /// Create a CMSampleBuffer from an EncodedFrame for writing to AVAssetWriter.
    private static func createSampleBuffer(from frame: EncodedFrame,
                                            formatDescription: CMFormatDescription,
                                            baseTime: CMTime) -> CMSampleBuffer? {
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

        status = data.withUnsafeBytes { rawPtr -> OSStatus in
            guard let ptr = rawPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: ptr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let pts = CMTimeSubtract(frame.pts, baseTime)
        let dts = CMTimeSubtract(frame.dts, baseTime)
        // Use PTS for DTS when no B-frames, and ensure duration is valid
        let dur = frame.duration.isValid && frame.duration.seconds > 0
            ? frame.duration
            : CMTimeMake(value: 1, timescale: 60)
        var timing = CMSampleTimingInfo(
            duration: dur,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts.isValid ? dts : pts
        )
        var sampleSize = data.count

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        if status == noErr, let sb = sampleBuffer, frame.isKeyframe {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true)
            if let arr = attachments as? [NSMutableDictionary], let dict = arr.first {
                dict[kCMSampleAttachmentKey_DependsOnOthers] = false
            }
        }

        return status == noErr ? sampleBuffer : nil
    }
}
