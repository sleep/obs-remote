import Foundation
import CoreMedia

public final class ReplayBuffer {

    private var frames: [EncodedFrame] = []
    private let lock = NSLock()
    private let maxDuration: Double
    private var totalBytes: Int = 0

    public init(duration: Double = 30.0) {
        self.maxDuration = duration
        frames.reserveCapacity(Int(60 * duration))
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

        var removeCount = 0
        for i in 0..<frames.count - 1 {
            if CMTimeCompare(frames[i].pts, cutoff) < 0 {
                removeCount = i + 1
            } else {
                break
            }
        }

        if removeCount > 0 {
            while removeCount > 0 && !frames[removeCount].isKeyframe {
                removeCount -= 1
            }
            if removeCount > 0 {
                for i in 0..<removeCount { totalBytes -= frames[i].size }
                frames.removeFirst(removeCount)
            }
        }
    }
}
