import Foundation
import VideoToolbox
import CoreMedia

/// Stores a single encoded H.264 frame with timing information.
struct EncodedFrame {
    let data: Data
    let isKeyframe: Bool
    let pts: CMTime
    let dts: CMTime
    let duration: CMTime
    /// SPS/PPS data needed to initialize a decoder or write a file header.
    /// Only present on keyframes.
    let parameterSets: Data?

    /// Total size in bytes.
    var size: Int { data.count + (parameterSets?.count ?? 0) }
}

/// Hardware-accelerated H.264 encoder using VideoToolbox.
/// Uses the M-series media engine for near-zero CPU/GPU encoding.
final class HardwareEncoder {

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let fps: Int
    private let bitrate: Int

    /// Called on the encoder queue when a frame is encoded.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private let encoderQueue = DispatchQueue(label: "encoder", qos: .userInteractive)

    init(width: Int32 = 1920, height: Int32 = 1080, fps: Int = 60, bitrateMbps: Int = 20) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrateMbps * 1_000_000
    }

    func start() throws {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]

        var sessionOut: VTCompressionSession?

        // Use the C callback API (outputHandler variant requires macOS 14.6+)
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let refcon else { return }
            let encoder = Unmanaged<HardwareEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedBuffer(sampleBuffer)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refcon,
            compressionSessionOut: &sessionOut
        )

        guard status == noErr, let session = sessionOut else {
            throw CaptureError.encoderCreationFailed(status)
        }

        self.session = session

        // Configure for real-time, low-latency encoding on Apple Silicon
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
        print("[Encoder] Hardware H.264 encoder started (\(width)x\(height) @ \(fps)fps, \(bitrate/1_000_000)Mbps)")
    }

    /// Encode a raw video frame from the capture session.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) {
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

    /// Force a keyframe on the next encoded frame.
    func forceKeyframe() {
        guard let session else { return }
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: 1 as CFTypeRef
        )
        encoderQueue.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard let session = self.session else { return }
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: (self.fps * 2) as CFTypeRef
            )
        }
    }

    func stop() {
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
            data: data,
            isKeyframe: isKeyframe,
            pts: pts,
            dts: dts.isValid ? dts : pts,
            duration: duration,
            parameterSets: parameterSets
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
