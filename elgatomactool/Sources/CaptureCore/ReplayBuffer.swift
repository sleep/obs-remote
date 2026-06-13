import Foundation
import CoreMedia

public final class ReplayBuffer {

    private var frames: [EncodedFrame] = []
    private var audioSamples: [AudioSample] = []
    private let lock = NSLock()
    private(set) public var maxDuration: Double
    private(set) public var maxBytes: Int  // 0 = unlimited
    private var totalBytes: Int = 0
    private var audioBytes: Int = 0

    public init(duration: Double = 30.0, maxBytes: Int = 0) {
        self.maxDuration = duration
        self.maxBytes = maxBytes
        frames.reserveCapacity(Int(60 * duration))
    }

    /// Update buffer limits at runtime. Trims immediately if the new limits are tighter.
    public func updateLimits(duration: Double? = nil, maxBytes: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let d = duration { self.maxDuration = d }
        if let b = maxBytes { self.maxBytes = b }
        trimLocked()
    }

    /// A PTS gap larger than this between consecutive samples signals a
    /// clock-domain change (e.g. USB replug where the new capture session's
    /// host-time samples land in a different epoch from the surviving
    /// pre-replug ones). The normal trim can't shed those: its keyframe-search
    /// walks backward and stalls when the frame right after the stale one is a
    /// P-frame. A surviving stale frame later becomes the saved replay's start
    /// frame, and AVAssetWriter fills the gap with one multi-hour sample.
    private static let discontinuityThresholdSeconds: Double = 5.0

    public func append(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }

        if let last = frames.last,
           ReplayBuffer.isDiscontinuity(from: last.pts, to: frame.pts) {
            let lastS = CMTimeGetSeconds(last.pts)
            let curS = CMTimeGetSeconds(frame.pts)
            print("[ReplayBuffer] Video PTS discontinuity — dropping \(frames.count) stale frames + \(audioSamples.count) audio samples (last=\(lastS)s, cur=\(curS)s, gap=\(curS - lastS)s)")
            frames.removeAll(keepingCapacity: true)
            audioSamples.removeAll(keepingCapacity: true)
            totalBytes = 0
            audioBytes = 0
        }

        frames.append(frame)
        totalBytes += frame.size
        trimLocked()
    }

    private static func isDiscontinuity(from: CMTime, to: CMTime) -> Bool {
        guard from.isValid, to.isValid else { return true }
        let gap = CMTimeGetSeconds(CMTimeSubtract(to, from))
        guard gap.isFinite else { return true }
        return abs(gap) > discontinuityThresholdSeconds
    }

    /// Drop every buffered frame + audio sample. Called when the codec changes
    /// — mixed-codec frames can't be muxed into a single output file.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
        audioSamples.removeAll(keepingCapacity: true)
        totalBytes = 0
        audioBytes = 0
    }

    public func appendAudio(_ sample: AudioSample) {
        lock.lock()
        defer { lock.unlock() }

        if let last = audioSamples.last,
           ReplayBuffer.isDiscontinuity(from: last.pts, to: sample.pts) {
            let lastS = CMTimeGetSeconds(last.pts)
            let curS = CMTimeGetSeconds(sample.pts)
            print("[ReplayBuffer] Audio PTS discontinuity — dropping \(audioSamples.count) stale audio samples (last=\(lastS)s, cur=\(curS)s, gap=\(curS - lastS)s)")
            audioSamples.removeAll(keepingCapacity: true)
            audioBytes = 0
        }

        audioSamples.append(sample)
        audioBytes += sample.size
        trimAudioLocked()
    }

    public func getReplayFrames(lastSeconds seconds: Double? = nil) -> [EncodedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return getVideoFramesLocked(lastSeconds: seconds)
    }

    /// Return both video frames and matching audio samples for a replay, under a single lock.
    public func getReplayData(lastSeconds seconds: Double? = nil) -> (video: [EncodedFrame], audio: [AudioSample]) {
        lock.lock()
        defer { lock.unlock() }

        let video = getVideoFramesLocked(lastSeconds: seconds)
        guard let first = video.first, let last = video.last else { return ([], []) }

        let startPTS = first.pts
        let endPTS = last.pts
        let audio = audioSamples.filter { sample in
            CMTimeCompare(sample.pts, startPTS) >= 0 && CMTimeCompare(sample.pts, endPTS) <= 0
        }
        return (video, audio)
    }

    private func getVideoFramesLocked(lastSeconds seconds: Double? = nil) -> [EncodedFrame] {
        guard !frames.isEmpty else { return [] }

        let duration = seconds ?? maxDuration
        let latestPTS = frames.last!.pts
        let cutoff = CMTimeSubtract(latestPTS, CMTimeMakeWithSeconds(duration, preferredTimescale: 90000))

        var startIndex = 0
        for i in stride(from: frames.count - 1, through: 0, by: -1) {
            if frames[i].isKeyframe && CMTimeCompare(frames[i].pts, cutoff) <= 0 {
                startIndex = i
                break
            }
        }

        if !frames[startIndex].isKeyframe {
            for i in 0..<frames.count {
                if frames[i].isKeyframe { startIndex = i; break }
            }
        }

        if !frames[startIndex].isKeyframe { return [] }
        return Array(frames[startIndex...])
    }

    /// Bytes written in the most recent `window` seconds of content.
    public func recentBytes(window: Double = 1.0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let last = frames.last else { return 0 }
        let cutoff = CMTimeSubtract(last.pts, CMTimeMakeWithSeconds(window, preferredTimescale: 90000))
        var bytes = 0
        for i in stride(from: frames.count - 1, through: 0, by: -1) {
            if CMTimeCompare(frames[i].pts, cutoff) < 0 { break }
            bytes += frames[i].size
        }
        return bytes
    }

    public var stats: (frameCount: Int, bytes: Int, duration: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count >= 2 else { return (frames.count, totalBytes, 0) }
        let dur = CMTimeGetSeconds(CMTimeSubtract(frames.last!.pts, frames.first!.pts))
        return (frames.count, totalBytes, dur)
    }

    private func trimLocked() {
        guard frames.count >= 2 else { return }

        let latestPTS = frames.last!.pts
        let cutoff = CMTimeSubtract(latestPTS, CMTimeMakeWithSeconds(maxDuration + 2.0, preferredTimescale: 90000))

        // Find how many frames exceed the duration limit
        var removeCount = 0
        for i in 0..<frames.count - 1 {
            if CMTimeCompare(frames[i].pts, cutoff) < 0 {
                removeCount = i + 1
            } else {
                break
            }
        }

        // Also enforce RAM limit: keep removing GOPs from the front if over budget
        if maxBytes > 0 && totalBytes > maxBytes && removeCount < frames.count - 1 {
            var remaining = totalBytes
            // Pre-subtract bytes of frames already slated for removal by the duration cutoff
            for j in 0..<removeCount { remaining -= frames[j].size }
            var i = removeCount
            while i < frames.count - 1 {
                remaining -= frames[i].size
                if remaining <= maxBytes { removeCount = i + 1; break }
                i += 1
            }
        }

        if removeCount > 0 {
            while removeCount > 0 && removeCount < frames.count && !frames[removeCount].isKeyframe {
                removeCount -= 1
            }
            if removeCount > 0 {
                for i in 0..<removeCount { totalBytes -= frames[i].size }
                frames.removeFirst(removeCount)
            }
        }

        trimAudioLocked()
    }

    /// Trim audio whose PTS is older than:
    ///   - the first kept video frame (so audio doesn't outlive its video), or
    ///   - `maxDuration + 2.0` seconds before the latest audio PTS (so a paused-video
    ///     stream with live audio doesn't grow without bound).
    /// Whichever cutoff is later wins.
    private func trimAudioLocked() {
        guard !audioSamples.isEmpty else { return }

        let latestAudioPts = audioSamples.last!.pts
        let durationCutoff = CMTimeSubtract(latestAudioPts,
                                            CMTimeMakeWithSeconds(maxDuration + 2.0, preferredTimescale: 90000))
        let cutoff: CMTime
        if let firstFrame = frames.first {
            cutoff = CMTimeCompare(firstFrame.pts, durationCutoff) > 0 ? firstFrame.pts : durationCutoff
        } else {
            cutoff = durationCutoff
        }

        var audioRemoveCount = 0
        for i in 0..<audioSamples.count {
            if CMTimeCompare(audioSamples[i].pts, cutoff) < 0 {
                audioRemoveCount = i + 1
            } else {
                break
            }
        }
        if audioRemoveCount > 0 {
            for i in 0..<audioRemoveCount { audioBytes -= audioSamples[i].size }
            audioSamples.removeFirst(audioRemoveCount)
        }
    }
}
