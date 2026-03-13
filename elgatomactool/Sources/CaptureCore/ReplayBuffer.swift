import Foundation
import CoreMedia

public final class ReplayBuffer {

    private var frames: [EncodedFrame] = []
    private let lock = NSLock()
    private(set) public var maxDuration: Double
    private(set) public var maxBytes: Int  // 0 = unlimited
    private var totalBytes: Int = 0

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

    public func append(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
        totalBytes += frame.size
        trimLocked()
    }

    public func getReplayFrames(lastSeconds seconds: Double? = nil) -> [EncodedFrame] {
        lock.lock()
        defer { lock.unlock() }

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
            for i in removeCount..<frames.count - 1 {
                // Estimate remaining bytes after removing up to i+1
                var remaining = totalBytes
                for j in 0...i { remaining -= frames[j].size }
                if remaining <= maxBytes { removeCount = i + 1; break }
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
    }
}
