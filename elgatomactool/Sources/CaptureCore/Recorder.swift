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

    /// Start recording to a new MP4/MOV file. Returns the file path.
    @discardableResult
    public func startRecording(width: Int = 1920, height: Int = 1080,
                               codec: CaptureCodec = .h264,
                               sourceFormatHint: CMFormatDescription? = nil,
                               audioFormatHint: CMFormatDescription? = nil) throws -> URL {
        let filename = Recorder.timestampedFilename(prefix: "recording", ext: codec.fileExtension)
        let url = outputDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)

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
    ///
    /// Video and audio are pushed via `requestMediaDataWhenReady` on dedicated queues so
    /// AVAssetWriter can drain both tracks in parallel. Writing all video before any audio
    /// stalls the writer (the video input's high-water mark trips while it waits for audio
    /// to interleave with) — that's the deadlock this code is designed to avoid.
    public static func writeFrames(_ frames: [EncodedFrame], audioSamples: [AudioSample] = [],
                            to url: URL,
                            fileType: AVFileType = .mp4,
                            width: Int = 1920, height: Int = 1080) async -> Bool {
        // Drop any leading non-keyframes — the writer can't start mid-GOP
        let startIdx = frames.firstIndex(where: { $0.isKeyframe }) ?? frames.count
        var usable = Array(frames[startIdx...])
        guard !usable.isEmpty else {
            print("[Recorder] No keyframes found in \(frames.count) frames, cannot write replay")
            return false
        }

        // Belt-and-braces against a PTS discontinuity slipping past the replay
        // buffer's guard. A single stale frame in front of a clock-domain change
        // would otherwise be written as the file's start and the gap to the next
        // sample would be encoded as a multi-hour first-frame duration. Keep only
        // the segment after the last discontinuity, snapped to the next keyframe.
        var splitIndex = 0
        for i in 1..<usable.count {
            let prev = usable[i - 1].pts
            let curr = usable[i].pts
            guard prev.isValid, curr.isValid else { splitIndex = i; continue }
            let gap = CMTimeGetSeconds(CMTimeSubtract(curr, prev))
            if !gap.isFinite || abs(gap) > 5.0 {
                splitIndex = i
            }
        }
        if splitIndex > 0 {
            while splitIndex < usable.count && !usable[splitIndex].isKeyframe {
                splitIndex += 1
            }
            guard splitIndex < usable.count else {
                print("[Recorder] PTS discontinuity but no trailing keyframe — cannot write replay")
                return false
            }
            print("[Recorder] PTS discontinuity in replay buffer — skipping \(splitIndex) stale frames, keeping \(usable.count - splitIndex)")
            usable = Array(usable[splitIndex...])
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            // Overwrite any leftover file at this path (e.g. an empty file from a previous hung save)
            try? FileManager.default.removeItem(at: url)

            let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

            // Intra-only codecs (ProRes) carry the format description on every
            // frame; H.264 keyframes need it reassembled from SPS/PPS.
            let formatDesc: CMFormatDescription
            if let fd = usable[0].formatDescription {
                formatDesc = fd
            } else if let fd = createFormatDescription(from: usable[0]) {
                formatDesc = fd
            } else {
                print("[Recorder] Failed to create format description")
                return false
            }

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                                 sourceFormatHint: formatDesc)
            // Treating data as real-time gives AVAssetWriter the larger internal buffer it
            // uses for live capture, which avoids spurious high-water-mark stalls when we
            // batch-feed a 60+ second replay. We're still feeding sequentially, just faster.
            videoInput.expectsMediaDataInRealTime = true
            writer.add(videoInput)

            // Filter out audio samples whose PTS is before the first video keyframe.
            // Those would map to negative timestamps the writer rejects, and the writer
            // could then stall on the never-appended remainder.
            let baseTime = usable[0].pts
            let endTime = usable.last!.pts
            let filteredAudio = audioSamples.filter { sample in
                CMTimeCompare(sample.pts, baseTime) >= 0 &&
                CMTimeCompare(sample.pts, endTime) <= 0
            }

            // Add audio track if audio samples are available
            var audioInput: AVAssetWriterInput?
            if let firstAudio = filteredAudio.first,
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
                ai.expectsMediaDataInRealTime = true
                writer.add(ai)
                audioInput = ai
            }

            guard writer.startWriting() else {
                print("[Recorder] startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
                return false
            }
            writer.startSession(atSourceTime: .zero)

            // Drive each input from its own queue. Apple's `requestMediaDataWhenReady` is
            // pull-based: it calls back when the input is ready and we feed as much as we can.
            // Running video and audio on separate queues lets the writer interleave properly.
            let videoQueue = DispatchQueue(label: "elgato.replay.write.video")
            let audioQueue = DispatchQueue(label: "elgato.replay.write.audio")

            // Watchdog timeout for finishWriting. If finalisation hangs (disk stall, FUSE
            // wedge, sandbox glitch), we cancel the writer and resume with failure rather
            // than blocking the awaiter forever.
            let finishTimeoutSeconds: Double = 10

            return await withCheckedContinuation { continuation in
                let stateLock = NSLock()
                var videoDone = false
                var audioDone = (audioInput == nil)
                var videoIndex = 0
                var audioIndex = 0
                var videoWritten = 0
                var audioWritten = 0
                var continuationResumed = false
                // Separate flag guarding the actual continuation.resume call. The
                // finishWriting callback and the watchdog race for this; exactly one wins.
                var resumeCompleted = false

                func finalizeIfReady() {
                    stateLock.lock()
                    let canFinalize = videoDone && audioDone && !continuationResumed
                    if canFinalize { continuationResumed = true }
                    stateLock.unlock()
                    guard canFinalize else { return }

                    print("[Recorder] Finalizing replay (\(videoWritten) video, \(audioWritten) audio)")

                    // Schedule the watchdog before invoking finishWriting so we cover the
                    // entire finalisation window. cancelWriting() is documented thread-safe.
                    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                    watchdog.schedule(deadline: .now() + finishTimeoutSeconds)
                    watchdog.setEventHandler {
                        stateLock.lock()
                        let shouldResume = !resumeCompleted
                        if shouldResume { resumeCompleted = true }
                        stateLock.unlock()
                        guard shouldResume else { return }
                        print("[Recorder] finishWriting timed out after \(Int(finishTimeoutSeconds))s — resuming with failure")
                        writer.cancelWriting()
                        continuation.resume(returning: false)
                    }
                    watchdog.resume()

                    writer.finishWriting {
                        stateLock.lock()
                        let shouldResume = !resumeCompleted
                        if shouldResume { resumeCompleted = true }
                        stateLock.unlock()
                        // Cancel the watchdog regardless — if we lost the race it's already
                        // fired, but cancelling an already-fired one-shot timer is a no-op.
                        watchdog.cancel()
                        guard shouldResume else { return }
                        let success = writer.status == .completed
                        if !success {
                            print("[Recorder] Replay write failed: \(writer.error?.localizedDescription ?? "unknown")")
                        }
                        continuation.resume(returning: success)
                    }
                }

                videoInput.requestMediaDataWhenReady(on: videoQueue) {
                    while videoInput.isReadyForMoreMediaData {
                        guard writer.status == .writing else {
                            print("[Recorder] Writer not writing during video pump: status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
                            videoInput.markAsFinished()
                            stateLock.lock(); videoDone = true; stateLock.unlock()
                            finalizeIfReady()
                            return
                        }
                        if videoIndex >= usable.count {
                            videoInput.markAsFinished()
                            stateLock.lock(); videoDone = true; stateLock.unlock()
                            finalizeIfReady()
                            return
                        }
                        let frame = usable[videoIndex]
                        videoIndex += 1
                        guard let sb = createSampleBuffer(from: frame, formatDescription: formatDesc, baseTime: baseTime) else {
                            continue
                        }
                        if !videoInput.append(sb) {
                            print("[Recorder] Video append failed at frame \(videoWritten): \(writer.error?.localizedDescription ?? "unknown")")
                            videoInput.markAsFinished()
                            stateLock.lock(); videoDone = true; stateLock.unlock()
                            finalizeIfReady()
                            return
                        }
                        videoWritten += 1
                    }
                }

                if let aInput = audioInput {
                    aInput.requestMediaDataWhenReady(on: audioQueue) {
                        while aInput.isReadyForMoreMediaData {
                            guard writer.status == .writing else {
                                print("[Recorder] Writer not writing during audio pump: status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
                                aInput.markAsFinished()
                                stateLock.lock(); audioDone = true; stateLock.unlock()
                                finalizeIfReady()
                                return
                            }
                            if audioIndex >= filteredAudio.count {
                                aInput.markAsFinished()
                                stateLock.lock(); audioDone = true; stateLock.unlock()
                                finalizeIfReady()
                                return
                            }
                            let sample = filteredAudio[audioIndex]
                            audioIndex += 1
                            guard let sb = createAudioSampleBuffer(from: sample, baseTime: baseTime) else {
                                continue
                            }
                            if !aInput.append(sb) {
                                print("[Recorder] Audio append failed at sample \(audioWritten): \(writer.error?.localizedDescription ?? "unknown")")
                                aInput.markAsFinished()
                                stateLock.lock(); audioDone = true; stateLock.unlock()
                                finalizeIfReady()
                                return
                            }
                            audioWritten += 1
                        }
                    }
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

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func timestampedFilename(prefix: String, ext: String) -> String {
        return "\(prefix)_\(Self.timestampFormatter.string(from: Date())).\(ext)"
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
