import Foundation
import AVFoundation

/// Shared formatting helpers used by the ContentView region sub-views.
enum ViewFormatters {
    static func formatDuration(_ seconds: Double) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m\(secs)s" : "\(mins)m"
        }
        return "\(Int(seconds))s"
    }

    static func formatRAM(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1fG", mb / 1024)
        }
        return String(format: "%.0fM", mb)
    }

    static func formatRecordingDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func isElgatoDevice(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        let keywords = ["elgato", "cam link", "hd60", "4k60", "game capture"]
        return keywords.contains(where: { name.contains($0) })
    }

    static func thumbnailAgeLabel(_ date: Date) -> String {
        let age = Int(Date().timeIntervalSince(date))
        if age < 60 { return "-\(age)s" }
        return "-\(age / 60)m\(age % 60)s"
    }
}
