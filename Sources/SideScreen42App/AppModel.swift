import AppKit
import ServiceManagement
import SideScreenCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case waiting                // 分享中，還沒有接收端
        case streaming(String)      // 接收端位址
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var stats = StreamStats()
    @Published private(set) var urls: [String] = []
    @Published private(set) var needsScreenRecording = false
    @Published private(set) var loginItemStatus = SMAppService.mainApp.status

    @AppStorage("port") var port = 8765
    @AppStorage("bitrateMbps") var bitrateMbps = 12.0
    @AppStorage("mode") var mode = "1504x1003"
    @AppStorage("shareAtLaunch") var shareAtLaunch = true

    private var streamer: Streamer?
    private let logger = FileLogger()
    private var quietCount = 0

    init() {
        SideScreenLog.handler = { [logger] line in logger.write(line) }
    }

    var isSharing: Bool {
        switch state {
        case .starting, .waiting, .streaming: true
        default: false
        }
    }

    var symbolName: String {
        switch state {
        case .streaming: "display.2"
        case .waiting, .starting: "display"
        case .stopped: "rectangle.slash"
        case .failed: "display.trianglebadge.exclamationmark"
        }
    }

    var statusText: String {
        switch state {
        case .stopped: "已停止分享"
        case .starting: "啟動中⋯"
        case .waiting: "分享中，等待接收端連線"
        case .streaming(let client): "\(client)正在觀看"
        case .failed(let msg): msg
        }
    }

    var detailText: String? {
        guard case .streaming = state else { return nil }
        return String(format: "%.0f fps · %.1f Mbps", stats.sendFPS, stats.mbps)
    }

    var logURL: URL { logger.url }

    func start() {
        guard !isSharing else { return }
        var cfg = StreamerConfig()
        cfg.port = UInt16(clamping: port)
        cfg.bitrateMbps = bitrateMbps
        cfg.mode = mode
        let s = Streamer(config: cfg)
        s.onClientChange = { [weak self] client in
            guard let self, self.streamer === s else { return }
            self.state = client.map { .streaming($0) } ?? .waiting
        }
        s.onStats = { [weak self] st in self?.record(st) }
        s.onFatal = { [weak self] e in
            guard let self, self.streamer === s else { return }
            Task { await self.stop(); self.state = .failed(e.localizedDescription) }
        }
        streamer = s
        state = .starting
        needsScreenRecording = false
        log("開始分享：埠 \(cfg.port)，\(cfg.bitrateMbps) Mbps，模式 \(cfg.mode)")
        Task {
            do {
                try await s.start(statsInterval: 2)
                guard streamer === s else { return }
                urls = s.urls
                if state == .starting { state = .waiting }
            } catch {
                guard streamer === s else { return }
                streamer = nil
                if error is SideScreenError {
                    state = .failed(error.localizedDescription)
                } else {
                    needsScreenRecording = true
                    state = .failed("需要「螢幕與系統錄音」權限")
                }
                log("無法開始分享：\(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        guard let s = streamer else { return }
        streamer = nil
        await s.stop()
        state = .stopped
        stats = StreamStats()
        log("停止分享")
    }

    func toggle() {
        if isSharing { Task { await stop() } } else { start() }
    }

    /// 設定改了：分享中就重開一次，讓新設定生效
    func applySettings() {
        guard isSharing else { return }
        Task {
            await stop()
            start()
        }
    }

    func copyURL() {
        guard let url = urls.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealReceiver() {
        if let url = Bundle.main.url(forResource: "SideScreen-receiver", withExtension: "html") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logger.url])
    }

    // MARK: 登入時打開（每次都讀系統狀態，使用者可能在系統設定裡關掉）

    var opensAtLogin: Bool { loginItemStatus == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("登入項目設定失敗：\(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    func refreshLoginItem() { loginItemStatus = SMAppService.mainApp.status }

    // MARK: 統計：有畫面在送、有丟幀、或每分鐘一次才寫進記錄檔

    private func record(_ s: StreamStats) {
        stats = s
        quietCount += 1
        guard s.sendFPS > 0 || s.dropped > 0 || quietCount >= 30 else { return }
        quietCount = 0
        log(String(format: "擷取 %.1f fps｜送出 %.1f fps｜丟棄 %d｜關鍵幀 %d｜%.2f Mbps｜編碼 %.1f/%.1f ms｜最慢送出 %.0f ms｜%@",
                   s.captureFPS, s.sendFPS, s.dropped, s.keyframes, s.mbps, s.encodeAvgMs, s.encodeMaxMs, s.maxSendMs, s.client ?? "等待連線"))
    }

    private func log(_ msg: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        logger.write("[\(f.string(from: Date()))] \(msg)")
    }
}

/// 記錄檔：~/Library/Logs/SideScreen42/sidescreen.log，接續寫入不覆蓋，超過 5 MB 輪替一份
final class FileLogger: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "sidescreen.log")
    private var handle: FileHandle?
    private var dayStamp = ""

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SideScreen42")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sidescreen.log")
    }

    func write(_ line: String) {
        queue.async { [self] in
            if handle == nil { open() }
            // 時間戳只有時分秒，換日時補一行日期
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let today = f.string(from: Date())
            if today != dayStamp {
                dayStamp = today
                handle?.write("—— \(today) ——\n".data(using: .utf8)!)
            }
            handle?.write((line + "\n").data(using: .utf8)!)
            if let size = try? handle?.offset(), size > 5_000_000 { rotate() }
        }
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotate() {
        try? handle?.close(); handle = nil
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        open()
    }
}
