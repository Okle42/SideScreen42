import CoreMedia
import Foundation

public struct StreamerConfig: Equatable {
    public var port: UInt16 = 8765
    public var bitrateMbps: Double = 12
    public var fps = 60
    public var mode = "1504x1003"       // 虛擬螢幕預設模式（point）
    public var width = 2256             // 編碼輸出像素（Surface 實體解析度）
    public var height = 1504
    public var dumpPath: String?

    public init() {}
}

public struct StreamStats {
    public var captureFPS = 0.0
    public var sendFPS = 0.0
    public var dropped = 0
    public var keyframes = 0
    public var mbps = 0.0
    /// 這段期間單幀從交給 socket 到送完的最長時間（Wi‑Fi 卡住時會變大）
    public var maxSendMs = 0.0
    /// 畫面交給編碼器 → 編好（ms）
    public var encodeAvgMs = 0.0
    public var encodeMaxMs = 0.0
    public var client: String?

    public init(captureFPS: Double = 0, sendFPS: Double = 0, dropped: Int = 0, keyframes: Int = 0,
                mbps: Double = 0, maxSendMs: Double = 0, client: String? = nil) {
        self.captureFPS = captureFPS; self.sendFPS = sendFPS; self.dropped = dropped
        self.keyframes = keyframes; self.mbps = mbps; self.maxSendMs = maxSendMs; self.client = client
    }
}

/// 整條管線：虛擬螢幕 → 擷取 → 編碼 → WebSocket。命令列與 App 共用
@MainActor
public final class Streamer {
    public let config: StreamerConfig
    public private(set) var running = false

    public var onStats: ((StreamStats) -> Void)?
    public var onClientChange: ((String?) -> Void)?
    /// 無法繼續（埠被占、權限不足…），呼叫端應該 stop()
    public var onFatal: ((Error) -> Void)?

    private var display: VirtualDisplay?
    private var encoder: Encoder?
    private var capture: Capture?
    private var server: Server?
    private var dumpHandle: FileHandle?
    private var statTimer: DispatchSourceTimer?
    private var lastStatTime = Date()

    public init(config: StreamerConfig) {
        self.config = config
    }

    public var urls: [String] { lanAddresses().map { "ws://\($0):\(config.port)/stream" } }

    public func start(statsInterval: TimeInterval = 5) async throws {
        guard !running else { return }
        let cfg = config
        do {
            display = try VirtualDisplay(preferredMode: cfg.mode)
            let enc = try Encoder(width: cfg.width, height: cfg.height, fps: cfg.fps, bitrateMbps: cfg.bitrateMbps)
            let cap = Capture(encoder: enc)
            let srv = Server(port: cfg.port)
            encoder = enc; capture = cap; server = srv

            if let path = cfg.dumpPath {
                FileManager.default.createFile(atPath: path, contents: nil)
                dumpHandle = FileHandle(forWritingAtPath: path)
                log("同時輸出到 \(path)（ffplay \(path) 可播放）")
            }
            let dumping = dumpHandle != nil
            enc.onFrame = { [weak self, srv, dumpHandle] f in
                dumpHandle?.write(f.annexB)
                srv.send(f, width: cfg.width, height: cfg.height, fps: cfg.fps)
                _ = self
            }
            srv.onKeyframeRequest = { [cap] in cap.keyframeNow() }
            // 錄檔模式一律全速；否則沒人連線就待機
            srv.onClientChange = { [weak self, cap] client in
                cap.setActive(client != nil || dumping)
                DispatchQueue.main.async { self?.onClientChange?(client) }
            }
            srv.onFatal = { [weak self] e in DispatchQueue.main.async { self?.onFatal?(e) } }
            try srv.start()

            // 被「停止共享」之類的動作停掉時自動接回
            cap.onStopped = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let self, self.running else { return }
                    log("擷取被系統停止，重新開始")
                    Task { @MainActor in try? await self.startCapture() }
                }
            }
            running = true
            try await startCapture()
        } catch {
            await stop()
            throw error
        }

        lastStatTime = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + statsInterval, repeating: statsInterval)
        t.setEventHandler { [weak self] in Task { @MainActor in self?.emitStats() } }
        t.resume()
        statTimer = t
    }

    private func startCapture() async throws {
        guard let capture, let display, let server else { return }
        try await capture.start(displayID: display.displayID, width: config.width, height: config.height, fps: config.fps)
        capture.setActive(server.hasClient || dumpHandle != nil)
        if server.hasClient { capture.keyframeNow() }
    }

    private func emitStats() {
        guard let capture, let server else { return }
        let dt = max(0.001, Date().timeIntervalSince(lastStatTime))
        lastStatTime = Date()
        let cap = capture.takeFrameCount()
        let s = server.takeStats()
        let enc = encoder?.takeEncodeStats() ?? (avg: 0, max: 0)
        var st = StreamStats(captureFPS: Double(cap) / dt, sendFPS: Double(s.sent) / dt, dropped: s.dropped,
                             keyframes: s.keyframes, mbps: Double(s.bytes) * 8 / dt / 1_000_000,
                             maxSendMs: s.maxSendMs, client: s.client)
        st.encodeAvgMs = enc.avg
        st.encodeMaxMs = enc.max
        onStats?(st)
    }

    /// 停擷取、關伺服器、移除虛擬螢幕
    public func stop() async {
        statTimer?.cancel(); statTimer = nil
        running = false
        await capture?.stop()
        encoder?.invalidate()
        server?.stop()
        try? dumpHandle?.close()
        capture = nil; encoder = nil; server = nil; dumpHandle = nil
        if display != nil {
            display = nil
            log("虛擬螢幕已移除")
        }
    }
}
