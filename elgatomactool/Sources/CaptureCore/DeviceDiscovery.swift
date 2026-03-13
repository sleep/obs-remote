import AVFoundation

public enum DeviceDiscovery {

    /// Returns all external video capture devices.
    public static func findCaptureDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: .video,
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

    /// Lists all discovered capture devices to stdout.
    public static func printDevices() {
        let devices = findCaptureDevices()
        if devices.isEmpty {
            print("No external capture devices found.")
            print("Make sure your Elgato is plugged in and recognized by macOS.")
            return
        }
        print("Found \(devices.count) capture device(s):")
        for (i, device) in devices.enumerated() {
            print("  [\(i)] \(device.localizedName) (\(device.uniqueID))")
            for format in device.formats {
                let desc = format.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let ranges = format.videoSupportedFrameRateRanges
                let maxFPS = ranges.map(\.maxFrameRate).max() ?? 0
                if dims.width == 1920 && dims.height == 1080 && maxFPS >= 59.0 {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    let fourCC = String(describing: mediaSubType)
                    print("    \(dims.width)x\(dims.height) @ \(Int(maxFPS))fps [\(fourCC)]")
                }
            }
        }
    }

    /// Finds the best 1080p60 format for a device. Prefers NV12 for hardware pipeline efficiency.
    public static func best1080p60Format(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?
        var bestScore = -1

        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width == 1920, dims.height == 1080 else { continue }

            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate >= 59.0 {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                var score = 0
                if subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { score = 3 }
                else if subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { score = 2 }
                else if subType == kCVPixelFormatType_32BGRA { score = 1 }

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
}
