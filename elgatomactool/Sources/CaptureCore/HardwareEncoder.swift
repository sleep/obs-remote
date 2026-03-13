import Foundation
import VideoToolbox
import CoreMedia

public struct EncodedFrame {
    public let data: Data
    public let isKeyframe: Bool
    public let pts: CMTime
    public let dts: CMTime
    public let duration: CMTime
    public let parameterSets: Data?

    public var size: Int { data.count + (parameterSets?.count ?? 0) }
}

public final class HardwareEncoder {

    private var session: VTCompressionSession?
    private var width: Int32
    private var height: Int32
    private var fps: Int
    private let bitrateMbps: Int
    private var bitrate: Int

    public var onEncodedFrame: ((EncodedFrame) -> Void)?

    private let encoderQueue = DispatchQueue(label: "encoder", qos: .userInteractive)

    public init(width: Int32 = 1920, height: Int32 = 1080, fps: Int = 60, bitrateMbps: Int = 20) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.bitrate = bitrateMbps * 1_000_000
    }

    /// Update dimensions before calling start(). Used when the actual device format differs from defaults.
    public func updateDimensions(width: Int32, height: Int32, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrateMbps * 1_000_000
    }

    public func start() throws {
        // Stop existing session if any
        if let session { VTCompressionSessionInvalidate(session); self.session = nil }

        var sessionOut: VTCompressionSession?

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let refcon else { return }
            let encoder = Unmanaged<HardwareEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedBuffer(sampleBuffer)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Try hardware encoder first, fall back to any available encoder
        let encoderSpecs: [[CFString: Any]] = [
            [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ],
            [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ],
            [:],  // No spec — use whatever's available
        ]

        var status: OSStatus = -1
        var usedHW = "unknown"
        for (i, spec) in encoderSpecs.enumerated() {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: callback,
                refcon: refcon,
                compressionSessionOut: &sessionOut
            )
            if status == noErr {
                usedHW = i == 0 ? "hardware (required)" : i == 1 ? "hardware (preferred)" : "software fallback"
                break
            }
        }

        guard status == noErr, let session = sessionOut else {
            throw CaptureError.encoderCreationFailed(status)
        }

        self.session = session

        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate),
            (kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 1] as [Int]),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 2),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
        ]

        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[Encoder] H.264 encoder started (\(width)x\(height) @ \(fps)fps, \(bitrate/1_000_000)Mbps, \(usedHW))")
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) {
        guard let session else { return }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    public func forceKeyframe() {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFTypeRef)
        encoderQueue.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard let session = self.session else { return }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (self.fps * 2) as CFTypeRef)
        }
    }

    public func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        print("[Encoder] Stopped")
    }

    // MARK: - Private

    fileprivate func handleEncodedBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let arr = attachments as? [[CFString: Any]], let first = arr.first {
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let dataPointer, totalLength > 0 else { return }
        let data = Data(bytes: dataPointer, count: totalLength)

        var parameterSets: Data?
        if isKeyframe, let formatDesc = sampleBuffer.formatDescription {
            parameterSets = extractParameterSets(from: formatDesc)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        let frame = EncodedFrame(
            data: data, isKeyframe: isKeyframe,
            pts: pts, dts: dts.isValid ? dts : pts,
            duration: duration, parameterSets: parameterSets
        )

        onEncodedFrame?(frame)
    }

    private func extractParameterSets(from formatDescription: CMFormatDescription) -> Data? {
        var data = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )

        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let ptr {
                let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
                data.append(contentsOf: startCode)
                data.append(ptr, count: size)
            }
        }
        return data.isEmpty ? nil : data
    }
}
