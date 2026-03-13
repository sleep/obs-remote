import AVFoundation

public enum DeviceDiscovery {

    /// Returns all video capture devices (external + built-in, so virtual cameras like OBS also appear).
    public static func findCaptureDevices() -> [AVCaptureDevice] {
        // Search all device types — Cam Link 4K can appear as .externalUnknown
        // or sometimes as other types depending on macOS version and drivers
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    /// Returns all audio input devices (external + built-in microphone).
    public static func findAudioDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    /// Returns the first Elgato device, or falls back to any external capture device.
    public static func findElgato() -> AVCaptureDevice? {
        let devices = findCaptureDevices()

        let elgatoKeywords = ["elgato", "cam link", "hd60", "4k60"]
        if let elgato = devices.first(where: { device in
            let name = device.localizedName.lowercased()
            return elgatoKeywords.contains(where: { name.contains($0) })
        }) {
            return elgato
        }

        return devices.first
    }

    /// Prints ALL formats for all devices (for debugging).
    public static func printDevices() {
        let devices = findCaptureDevices()
        if devices.isEmpty {
            print("No capture devices found.")
            return
        }
        print("Found \(devices.count) capture device(s):")
        for (i, device) in devices.enumerated() {
            print("  [\(i)] \(device.localizedName) (\(device.uniqueID))")
            print("       Active format: \(formatString(device.activeFormat))")
            print("       All formats:")
            for format in device.formats {
                print("         \(formatString(format))")
            }
        }
    }

    private static func formatString(_ format: AVCaptureDevice.Format) -> String {
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let subType = CMFormatDescriptionGetMediaSubType(desc)
        let ranges = format.videoSupportedFrameRateRanges
        let fpsStr = ranges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))fps" }.joined(separator: ", ")
        let fourCC = fourCCString(subType)
        return "\(dims.width)x\(dims.height) [\(fourCC)] \(fpsStr)"
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        if let s = String(bytes: bytes, encoding: .ascii) { return s }
        return String(code)
    }

    /// Finds the best format for a device. Prefers 1080p60 NV12, but falls back to
    /// any usable format if 1080p60 isn't available.
    public static func bestFormat(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        // Score each format: prefer 1080p, then high fps, then NV12 pixel format
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?
        var bestScore = -1

        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let subType = CMFormatDescriptionGetMediaSubType(desc)

            for range in format.videoSupportedFrameRateRanges {
                var score = 0

                // Resolution scoring (strongly prefer 1080p)
                if dims.width == 1920 && dims.height == 1080 { score += 10000 }
                else if dims.width >= 1280 { score += 5000 }
                else { score += Int(dims.width) }

                // FPS scoring (prefer 60, accept 30+)
                if range.maxFrameRate >= 59.0 { score += 1000 }
                else if range.maxFrameRate >= 29.0 { score += 500 }
                else { score += Int(range.maxFrameRate) }

                // Pixel format scoring (prefer NV12 for hardware encoder)
                if subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { score += 30 }
                else if subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { score += 20 }
                else if subType == kCVPixelFormatType_32BGRA { score += 10 }
                else { score += 1 }  // Accept any format

                if score > bestScore {
                    bestScore = score
                    bestFormat = format
                    bestRange = range
                }
            }
        }

        if let format = bestFormat, let range = bestRange {
            return (format, range)
        }
        return nil
    }

    /// Legacy: strict 1080p60 lookup.
    public static func best1080p60Format(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        return bestFormat(for: device)
    }
}
