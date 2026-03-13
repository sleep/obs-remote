import Foundation
import CoreMedia

/// Thread-safe circular buffer that retains the last N seconds of encoded H.264 frames.
/// When a replay is saved, frames from the nearest keyframe before the window start are written out.
final class ReplayBuffer {

    private var frames: [EncodedFrame] = []
    private let lock = NSLock()
    private let maxDuration: Double // seconds
    private var totalBytes: Int = 0

    /// Creates a replay buffer.
    /// - Parameter duration: How many seconds of video to keep (default 30).
    init(duration: Double = 30.0) {
        self.maxDuration = duration
        // Pre-allocate for ~60fps * duration frames
        frames.reserveCapacity(Int(60 * duration))
    }

    /// Add an encoded frame. Old frames beyond `maxDuration` are discarded.
    func append(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }

        frames.append(frame)
        totalBytes += frame.size

        trimLocked()
    }

    /// Returns all buffered frames starting from the nearest keyframe that covers
    /// at least `seconds` of history. Returns empty if no keyframe is available.
    func getReplayFrames(lastSeconds seconds: Double? = nil) -> [EncodedFrame] {
        lock.lock()
        defer { lock.unlock() }

        guard !frames.isEmpty else { return [] }

        let duration = seconds ?? maxDuration
        let latestPTS = frames.last!.pts
        let cutoff = CMTimeSubtract(latestPTS, CMTimeMakeWithSeconds(duration, preferredTimescale: 90000))

        // Find the nearest keyframe at or before cutoff
        var startIndex = 0
        for i in stride(from: frames.count - 1, through: 0, by: -1) {
            if frames[i].isKeyframe && CMTimeCompare(frames[i].pts, cutoff) <= 0 {
                startIndex = i
                break
            }
        }

        // If no keyframe found before cutoff, use the first keyframe available
        if !frames[startIndex].isKeyframe {
            for i in 0..<frames.count {
                if frames[i].isKeyframe {
                    startIndex = i
                    break
                }
            }
        }

        // Still no keyframe? Return empty
        if !frames[startIndex].isKeyframe {
            return []
        }

        return Array(frames[startIndex...])
    }

    /// Current buffer stats.
    var stats: (frameCount: Int, bytes: Int, duration: Double) {
        lock.lock()
        defer { lock.unlock() }

        guard frames.count >= 2 else { return (frames.count, totalBytes, 0) }
        let dur = CMTimeGetSeconds(CMTimeSubtract(frames.last!.pts, frames.first!.pts))
        return (frames.count, totalBytes, dur)
    }

    // MARK: - Private

    private func trimLocked() {
        guard frames.count >= 2 else { return }

        let latestPTS = frames.last!.pts
        let cutoff = CMTimeSubtract(latestPTS, CMTimeMakeWithSeconds(maxDuration + 2.0, preferredTimescale: 90000))

        // Remove frames older than cutoff, but keep the last keyframe before cutoff
        var removeCount = 0
        for i in 0..<frames.count - 1 {
            if CMTimeCompare(frames[i].pts, cutoff) < 0 {
                removeCount = i + 1
            } else {
                break
            }
        }

        // Ensure we only remove up to just before a keyframe so the buffer stays decodable
        if removeCount > 0 {
            // Walk back to keep the keyframe
            while removeCount > 0 && !frames[removeCount].isKeyframe {
                removeCount -= 1
            }

            if removeCount > 0 {
                for i in 0..<removeCount {
                    totalBytes -= frames[i].size
                }
                frames.removeFirst(removeCount)
            }
        }
    }
}
