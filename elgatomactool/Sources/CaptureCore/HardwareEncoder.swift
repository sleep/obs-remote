import AVFoundation
import Foundation
import VideoToolbox
import CoreMedia

/// Output codec for the capture pipeline. Picked once at session start — the
/// replay buffer can only hold frames from a single codec, so changing this
/// requires restarting the encoder + clearing the buffer.
public enum CaptureCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    /// H.264 hardware encoding via VideoToolbox. Lossy, bitrate-controlled.
    case h264 = "h264"

    /// Apple ProRes 422 HQ — visually lossless, intra-only, hardware-accelerated
    /// on Apple Silicon M1 Pro/Max/Ultra and M2/M3 (software fallback elsewhere).
    /// 4:2:2 chroma matches the typical HDMI capture-card source 1:1; ≈ 442 Mbps
    /// at 1080p60. Output container is QuickTime (.mov) for NLE compatibility.
    case proRes422HQ = "proRes422HQ"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .proRes422HQ: return "ProRes 422 HQ (Lossless)"
        }
    }

    public var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .proRes422HQ: return kCMVideoCodecType_AppleProRes422HQ
        }
    }

    public var fileExtension: String {
        switch self {
        case .h264: return "mp4"
        case .proRes422HQ: return "mov"
        }
    }

    public var fileType: AVFileType {
        switch self {
        case .h264: return .mp4
        case .proRes422HQ: return .mov
        }
    }

    /// True for codecs whose encoded packets are individually self-describing —
    /// every frame is a keyframe, the format description lives on the sample
    /// buffer directly, no NAL parameter sets to extract / reconstruct.
    public var isIntraOnly: Bool {
        switch self {
        case .h264: return false
        case .proRes422HQ: return true
        }
    }

    public var isLossless: Bool {
        switch self {
        case .h264: return false
        case .proRes422HQ: return true
        }
    }

    /// Approximate sustained bitrate (Mbps) used for pre-capture size estimates.
    /// Numbers scale linearly with pixels-per-second from Apple's published
    /// ProRes data-rate table (1920×1080×59.94 ProRes 422 HQ ≈ 442 Mbps).
    /// Returns 0 for codecs whose bitrate is caller-configured.
    public func estimatedMbps(width: Int, height: Int, fps: Double) -> Double {
        switch self {
        case .h264:
            return 0
        case .proRes422HQ:
            let basePixelsPerSec = 1920.0 * 1080.0 * 59.94
            let baseMbps = 442.0
            let pps = Double(width) * Double(height) * max(fps, 1)
            return pps / basePixelsPerSec * baseMbps
        }
    }
}

public struct EncodedFrame {
    public let data: Data
    public let isKeyframe: Bool
    public let pts: CMTime
    public let dts: CMTime
    public let duration: CMTime
    /// H.264 SPS/PPS parameter sets in Annex-B form. Nil for intra-only codecs
    /// like ProRes that carry their format inline on every sample buffer.
    public let parameterSets: Data?
    /// Self-contained format description from the source sample buffer.
    /// Populated for intra-only codecs (ProRes) so the recorder can write
    /// without reconstructing from parameter sets.
    public let formatDescription: CMFormatDescription?

    public init(data: Data, isKeyframe: Bool, pts: CMTime, dts: CMTime,
                duration: CMTime, parameterSets: Data? = nil,
                formatDescription: CMFormatDescription? = nil) {
        self.data = data
        self.isKeyframe = isKeyframe
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.parameterSets = parameterSets
        self.formatDescription = formatDescription
    }

    public var size: Int { data.count + (parameterSets?.count ?? 0) }
}

public struct AudioSample {
    public let data: Data
    public let pts: CMTime
    public let duration: CMTime
    public let numSamples: CMItemCount
    public let formatDescription: CMFormatDescription

    public var size: Int { data.count }
}

public final class HardwareEncoder {

    private var session: VTCompressionSession?
    private var width: Int32
    private var height: Int32
    private var fps: Int
    private var bitrateMbps: Int
    private var bitrate: Int
    private(set) public var codec: CaptureCodec

    public var onEncodedFrame: ((EncodedFrame) -> Void)?

    private let encoderQueue = DispatchQueue(label: "encoder", qos: .userInteractive)

    public init(width: Int32 = 1920, height: Int32 = 1080, fps: Int = 60,
                bitrateMbps: Int = 20, codec: CaptureCodec = .h264) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.bitrate = bitrateMbps * 1_000_000
        self.codec = codec
    }

    /// Update dimensions before calling start(). Used when the actual device format differs from defaults.
    public func updateDimensions(width: Int32, height: Int32, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrateMbps * 1_000_000
    }

    /// Update the target bitrate. If encoding is active, applies immediately to the live session.
    /// No-op for codecs (ProRes) whose bitrate is fixed by profile + resolution + fps.
    public func updateBitrate(mbps: Int) {
        bitrateMbps = mbps
        bitrate = mbps * 1_000_000
        guard codec == .h264 else {
            print("[Encoder] Bitrate property ignored for \(codec.displayName) (rate is profile-fixed)")
            return
        }
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 * 2, 1] as CFTypeRef)
        print("[Encoder] Bitrate updated to \(mbps)Mbps")
    }

    /// Change the output codec. Caller MUST stop the encoder + clear the replay
    /// buffer before / after calling this — mixed-codec frames cannot be muxed
    /// into a single output file.
    public func setCodec(_ codec: CaptureCodec) {
        self.codec = codec
    }

    public func start() throws {
        // Stop existing session if any
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }

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
                codecType: codec.codecType,
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

        // Properties shared by every codec. ProRes is intra-only so the keyframe
        // settings are inert there but harmless to set.
        var properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 2),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
        ]

        // H.264-specific: profile level + bitrate. ProRes ignores all of these —
        // its data rate is determined by profile + resolution + fps.
        if codec == .h264 {
            properties.append((kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel))
            properties.append((kVTCompressionPropertyKey_AverageBitRate, bitrate))
            properties.append((kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 1] as [Int]))
        }

        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        let rateLabel = codec == .h264 ? "\(bitrate/1_000_000)Mbps" : "lossless"
        print("[Encoder] \(codec.displayName) encoder started (\(width)x\(height) @ \(fps)fps, \(rateLabel), \(usedHW))")
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
        // Wrap the CMBlockBuffer's bytes without copying. Retain the block buffer
        // for the Data's lifetime: the deallocator closure captures it, so when
        // Data is freed the closure goes out of scope and the CMBlockBuffer
        // release fires. Downstream consumers (ReplayBuffer, Recorder) only
        // read these bytes — never mutate — so CoW won't trigger a copy.
        let retainedBuffer = dataBuffer
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(dataPointer),
            count: totalLength,
            deallocator: .custom { _, _ in
                _ = retainedBuffer  // keep retainedBuffer alive until Data is freed
            }
        )

        // H.264 keyframes carry SPS/PPS that the recorder later turns back into
        // a CMFormatDescription. Intra-only codecs (ProRes) hand us a complete
        // format description on every sample buffer — just hold a reference.
        var parameterSets: Data?
        var formatDescription: CMFormatDescription?
        if codec.isIntraOnly {
            formatDescription = sampleBuffer.formatDescription
        } else if isKeyframe, let formatDesc = sampleBuffer.formatDescription {
            parameterSets = extractParameterSets(from: formatDesc)
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        let frame = EncodedFrame(
            data: data, isKeyframe: isKeyframe,
            pts: pts, dts: dts.isValid ? dts : pts,
            duration: duration,
            parameterSets: parameterSets,
            formatDescription: formatDescription
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
