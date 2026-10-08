import CoreMedia
import Foundation
import VideoToolbox

public struct EncodedFrame {
    let isKeyframe: Bool
    /// 完整的二進位訊息：flags(1) + timestamp_us(8, BE) + Annex B，編碼時一次組好，傳送端不再複製
    let message: Data
    let codec: String?      // 只有關鍵幀會帶（從 SPS 取出）
    public var annexB: Data { message.subdata(in: 9..<message.count) }
}

/// VideoToolbox H.264 硬體編碼，輸出 Annex B（關鍵幀前附 SPS/PPS）
final class Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let lock = NSLock()
    private var forceNext = true
    var onFrame: ((EncodedFrame) -> Void)?
    /// 編碼耗時統計（畫面交給編碼器 → 編好），單位 ms
    private var encodeSum = 0.0, encodeMax = 0.0, encodeN = 0

    init(width: Int, height: Int, fps: Int, bitrateMbps: Double) throws {
        self.width = Int32(width)
        self.height = Int32(height)

        // 低延遲碼率控制會選到 rtvc 即時編碼器：實測 2256×1504 每幀 9 ms，一般的 ave.avc 要 15–16 ms
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var s: VTCompressionSession?
        var st = VTCompressionSessionCreate(
            allocator: nil, width: self.width, height: self.height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if st != noErr {
            // 低延遲碼率控制不支援時退回一般硬體編碼
            let spec2: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            st = VTCompressionSessionCreate(
                allocator: nil, width: self.width, height: self.height,
                codecType: kCMVideoCodecType_H264, encoderSpecification: spec2 as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard st == noErr, let session = s else { throw SideScreenError.encoderCreateFailed(st) }
        self.session = session

        let bps = bitrateMbps * 1_000_000
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: Int(bps),
            // 每秒最多 1.5 倍平均碼率，避免瞬間爆量
            kVTCompressionPropertyKey_DataRateLimits: [bps * 1.5 / 8, 1.0] as CFArray,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (k, v) in props {
            let r = VTSessionSetProperty(session, key: k, value: v as CFTypeRef)
            if r != noErr { log("警告：編碼器屬性 \(k) 設定失敗（\(r)）") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        // 低延遲碼率控制會選到 rtvc 即時編碼器，它不回報 UsingHardwareAcceleratedVideoEncoder，改印編碼器 ID
        var ref: Unmanaged<CFTypeRef>?
        var encoderID = "?"
        if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
                                 allocator: nil, valueOut: &ref) == noErr, let v = ref?.takeRetainedValue() as? String {
            encoderID = v
        }
        log("H.264 編碼器：\(width)x\(height) @\(fps)，\(bitrateMbps) Mbps，\(encoderID)")
    }

    /// 已要求關鍵幀、但還沒有新畫面把它編掉
    var keyframePending: Bool {
        lock.lock(); defer { lock.unlock() }
        return forceNext
    }

    /// 回傳這段期間的（平均, 最大）編碼耗時並歸零
    func takeEncodeStats() -> (avg: Double, max: Double) {
        lock.lock(); defer { encodeSum = 0; encodeMax = 0; encodeN = 0; lock.unlock() }
        return (encodeN > 0 ? encodeSum / Double(encodeN) : 0, encodeMax)
    }

    func requestKeyframe() {
        lock.lock(); forceNext = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock(); let force = forceNext; forceNext = false; lock.unlock()
        let opts: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let t0 = DispatchTime.now().uptimeNanoseconds
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: opts, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            self.lock.lock()
            self.encodeSum += ms; self.encodeN += 1; self.encodeMax = max(self.encodeMax, ms)
            self.lock.unlock()
            self.handle(sample)
        }
        if st != noErr {
            log("編碼失敗（\(st)）")
            if force { requestKeyframe() }
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func handle(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }

        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, (first[kCMSampleAttachmentKey_NotSync] as? Bool) == true {
            isKey = false
        }

        let total = CMBlockBufferGetDataLength(block)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let us = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)

        // 訊息標頭先寫好；AVCC 的長度前綴與 Annex B 起始碼一樣長，容量 = 標頭 + 參數集 + 本體
        var out = Data(capacity: 9 + 64 + total)
        out.append(isKey ? 1 : 0)
        withUnsafeBytes(of: us.bigEndian) { out.append(contentsOf: $0) }

        var codec: String?
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard let p, n > 0 else { continue }
                out.append(contentsOf: Self.startCode)
                out.append(p, count: n)
                // SPS（nal_unit_type 7）：profile_idc、constraint flags、level_idc
                if p[0] & 0x1f == 7, n >= 4 {
                    codec = String(format: "avc1.%02x%02x%02x", p[1], p[2], p[3])
                }
            }
        }

        // AVCC（4 byte 長度前綴）→ Annex B。block buffer 連續時直接讀，不連續才先拷出
        func convert(_ bytes: UnsafePointer<UInt8>) {
            var off = 0
            while off + 4 <= total {
                let len = Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
                off += 4
                guard len > 0, off + len <= total else { break }
                out.append(contentsOf: Self.startCode)
                out.append(bytes + off, count: len)
                off += len
            }
        }
        var contiguous = 0
        var ptr: UnsafeMutablePointer<CChar>?
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous,
                                       totalLengthOut: nil, dataPointerOut: &ptr) == noErr,
           let ptr, contiguous == total {
            ptr.withMemoryRebound(to: UInt8.self, capacity: total) { convert($0) }
        } else {
            var bytes = [UInt8](repeating: 0, count: total)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: &bytes) == noErr else { return }
            bytes.withUnsafeBufferPointer { convert($0.baseAddress!) }
        }

        onFrame?(EncodedFrame(isKeyframe: isKey, message: out, codec: codec))
    }
}
