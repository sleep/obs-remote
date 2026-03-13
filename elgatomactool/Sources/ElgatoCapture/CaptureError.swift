import Foundation

enum CaptureError: LocalizedError {
    case noDeviceFound
    case noSupportedFormat
    case captureSessionFailed(String)
    case encoderCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDeviceFound:
            return "No Elgato or external capture device found"
        case .noSupportedFormat:
            return "No 1080p60 format available on this device"
        case .captureSessionFailed(let reason):
            return "Capture session failed: \(reason)"
        case .encoderCreationFailed(let status):
            return "Hardware encoder creation failed (status: \(status)). Make sure hardware encoding is supported."
        }
    }
}
