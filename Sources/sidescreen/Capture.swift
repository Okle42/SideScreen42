import CoreMedia
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 擷取虛擬螢幕，輸出 NV12 給編碼器
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "sidescreen.capture", qos: .userInteractive)
    private let encoder: Encoder
    private var lastBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var frames = 0
    private var config: SCStreamConfiguration?
    private var fps = 60
    /// 沒有用戶端時待機：不編碼，擷取降到每秒 2 張（只為了手上永遠有最新畫面可以立刻編關鍵幀）
    private var active = true
    /// 擷取被系統停掉時通知（例如按了選單列的「停止共享」）
    var onStopped: (() -> Void)?
    private static let idleInterval = CMTime(value: 1, timescale: 2)
    /// 間隔設剛好 1/fps 時，畫面時間的微小抖動會讓 SCK 丟掉約 4% 的幀；放寬 10%，實際仍受螢幕 60 Hz 限制
    private static func activeInterval(_ fps: Int) -> CMTime { CMTime(value: 10, timescale: CMTimeScale(fps * 11)) }

    init(encoder: Encoder) {
        self.encoder = encoder
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        // 虛擬螢幕剛建立時 SCK 不一定立刻看得到，等最多 5 秒
        var target: SCDisplay?
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let display = target else { fail("ScreenCaptureKit 找不到虛擬螢幕（displayID=\(displayID)）") }

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.minimumFrameInterval = Self.activeInterval(fps)
        cfg.showsCursor = true
        cfg.queueDepth = 4          // 3 給 SCK 輪替，另外 1 張是我們留著重編關鍵幀用的
        cfg.colorSpaceName = CGColorSpace.itur_709
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.scalesToFit = true
        cfg.capturesAudio = false

        config = cfg
        self.fps = fps

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        queue.sync { active = true }
        log("開始擷取虛擬螢幕 → \(width)x\(height) NV12")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func setActive(_ on: Bool) {
        queue.async { [self] in
            guard on != active, let stream, let cfg = config else { return }
            active = on
            cfg.minimumFrameInterval = on ? Self.activeInterval(fps) : Self.idleInterval
            stream.updateConfiguration(cfg) { err in
                if let err { log("切換擷取頻率失敗：\(err.localizedDescription)") }
            }
            log(on ? "有用戶端：擷取恢復 \(fps) fps" : "沒有用戶端：待機（不編碼，擷取 2 fps）")
        }
    }

    /// 畫面靜止時 SCK 不送 frame；要關鍵幀時拿最後一張重編
    func keyframeNow() {
        encoder.requestKeyframe()
        queue.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self, let buf = self.lastBuffer else { return }
            // 30ms 內若已有新畫面進來，關鍵幀已經編掉了，這裡多編一次也無妨
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let pts = CMTimeMaximum(now, self.lastPTS + CMTime(value: 1, timescale: 1000))
            self.lastPTS = pts
            self.encoder.encode(buf, pts: pts)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let buf = CMSampleBufferGetImageBuffer(sb) else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if pts <= lastPTS { pts = lastPTS + CMTime(value: 1, timescale: 1000) }
        lastPTS = pts
        lastBuffer = buf
        guard active else { return }
        frames += 1
        encoder.encode(buf, pts: pts)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("擷取中斷：\(error.localizedDescription)")
        self.stream = nil
        onStopped?()
    }

    /// 給統計用，回傳後歸零
    func takeFrameCount() -> Int {
        queue.sync { defer { frames = 0 }; return frames }
    }
}
