import AVFoundation
import CoreMedia

/// Writes encoded H.264 frames to an MP4 file using AVAssetWriter.
public final class Recorder {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var isWriting = false
    private var sessionStarted = false
    private let outputDir: URL

    public init(outputDir: URL? = nil) {
        self.outputDir = outputDir ?? Recorder.defaultOutputDir()
    }

    /// Start recording to a new MP4 file. Returns the file path.
    @discardableResult
    public func startRecording(width: Int = 1920, height: Int = 1080) throws -> URL {
        let filename = Recorder.timestampedFilename(prefix: "recording", ext: "mp4")
        let url = outputDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // nil outputSettings = passthrough (we provide already-encoded H.264 data)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        input.expectsMediaDataInRealTime = true

        writer.add(input)
        writer.startWriting()

        self.assetWriter = writer
        self.videoInput = input
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

    /// Stop recording and finalize the file.
    public func stopRecording() async -> URL? {
        guard isWriting, let writer = assetWriter else { return nil }
        isWriting = false

        videoInput?.markAsFinished()

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
    public static func writeFrames(_ frames: [EncodedFrame], to url: URL,
                            width: Int = 1920, height: Int = 1080) async -> Bool {
        guard !frames.isEmpty else { return false }
        guard let firstKeyframe = frames.first(where: { $0.isKeyframe }) else { return false }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

            guard let formatDesc = createFormatDescription(from: firstKeyframe) else {
                print("[Recorder] Failed to create format description")
                return false
            }

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: formatDesc)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            writer.startWriting()

            let baseTime = frames[0].pts
            writer.startSession(atSourceTime: .zero)

            for frame in frames {
                guard let sampleBuffer = createSampleBuffer(
                    from: frame, formatDescription: formatDesc, baseTime: baseTime
                ) else { continue }

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                input.append(sampleBuffer)
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
        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: CMTimeSubtract(frame.pts, baseTime),
            decodeTimeStamp: CMTimeSubtract(frame.dts, baseTime)
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
