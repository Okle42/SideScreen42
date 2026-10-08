import Foundation
import Network

/// 單一用戶端的 WebSocket 伺服器（ws://<ip>:port/stream）
final class Server {
    private let queue = DispatchQueue(label: "sidescreen.server")
    private var client: NWConnection?
    private var inflight = 0
    private var needsKeyframe = true
    private var lastConfig: String?
    private static let maxInflight = 3

    var onKeyframeRequest: (() -> Void)?
    var onClientChange: ((String?) -> Void)?
    var onFatal: ((Error) -> Void)?
    private var stats = (sent: 0, dropped: 0, bytes: 0, keyframes: 0, maxSendMs: 0.0)

    private let port: UInt16
    private var listener: NWListener?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024
        let params = NWParameters.tcp
        params.serviceClass = .interactiveVideo   // Wi‑Fi WMM 視訊優先佇列
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener = l
        l.stateUpdateHandler = { [weak self, port] state in
            switch state {
            case .ready:
                log("伺服器已就緒，port \(port)")
            case .failed(let e):
                if case .posix(let code) = e, code == .EADDRINUSE {
                    self?.onFatal?(SideScreenError.portInUse(port))
                } else {
                    self?.onFatal?(SideScreenError.server("\(e)"))
                }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
    }

    func stop() {
        client?.cancel()
        listener?.cancel()
    }

    private func accept(_ conn: NWConnection) {
        log("收到連線請求：\(conn.endpoint)（等待 WebSocket 握手）")
        // 完成 WebSocket 握手（ready）才取代舊用戶端，半途的連線不會把正在看的人踢掉
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                if let old = self.client, old !== conn {
                    log("新用戶端連入，取代舊連線")
                    old.cancel()
                }
                self.client = conn
                self.onClientChange?(Self.describe(conn.endpoint))
                self.inflight = 0
                self.needsKeyframe = true
                log("用戶端已連線：\(conn.endpoint)")
                if let cfg = self.lastConfig { self.sendText(cfg, on: conn) }
                self.onKeyframeRequest?()
                self.receive(on: conn)
            case .waiting(let e):
                log("連線等待中（\(conn.endpoint)）：\(e)")
            case .failed(let e):
                log("連線錯誤（\(conn.endpoint)）：\(e)")
                conn.cancel()
            case .cancelled:
                self.drop(conn)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func drop(_ conn: NWConnection) {
        if client === conn {
            client = nil
            log("用戶端已斷線")
            onClientChange?(nil)
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, ctx, _, error in
            guard let self, let conn else { return }
            if let data, !data.isEmpty,
               let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .text {
                self.handleText(data)
            }
            if error == nil, self.client === conn { self.receive(on: conn) }
        }
    }

    private func handleText(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            log("收到無法解析的訊息，忽略")
            return
        }
        switch type {
        case "hello":
            log("用戶端 hello：client=\(obj["client"] ?? "?") 螢幕 \(obj["width"] ?? "?")x\(obj["height"] ?? "?")")
        case "keyframe":
            log("用戶端要求關鍵幀")
            needsKeyframe = true
            onKeyframeRequest?()
        default:
            break   // 看不懂的 type 直接忽略
        }
    }

    /// 編碼器每產出一幀呼叫一次（任意執行緒）
    func send(_ f: EncodedFrame, width: Int, height: Int, fps: Int) {
        queue.async { [self] in
            if let codec = f.codec {
                let cfg = #"{"type":"config","codec":"\#(codec)","width":\#(width),"height":\#(height),"fps":\#(fps)}"#
                if cfg != lastConfig {
                    lastConfig = cfg
                    log("串流設定：\(cfg)")
                    if let c = client { sendText(cfg, on: c) }
                }
            }
            guard let conn = client, conn.state == .ready else { return }
            if !f.isKeyframe && (needsKeyframe || inflight >= Self.maxInflight) {
                // 背壓：寧可掉幀也不累積延遲，掉了就改要關鍵幀
                stats.dropped += 1
                if !needsKeyframe {
                    needsKeyframe = true
                    onKeyframeRequest?()
                }
                return
            }
            if f.isKeyframe { needsKeyframe = false; stats.keyframes += 1 }

            let msg = f.message
            let t0 = DispatchTime.now().uptimeNanoseconds

            inflight += 1
            let ctx = NWConnection.ContentContext(identifier: "frame",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            conn.send(content: msg, contentContext: ctx, isComplete: true, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.inflight -= 1
                // 從交給 socket 到送完的時間：Wi‑Fi 卡住時這裡會變大
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                if ms > self.stats.maxSendMs { self.stats.maxSendMs = ms }
            })
            stats.sent += 1
            stats.bytes += msg.count
        }
    }

    private func sendText(_ s: String, on conn: NWConnection) {
        let ctx = NWConnection.ContentContext(identifier: "text",
                                              metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        conn.send(content: s.data(using: .utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    var hasClient: Bool { queue.sync { client != nil } }

    static func describe(_ e: NWEndpoint) -> String {
        if case .hostPort(let host, _) = e { return "\(host)" }
        return "\(e)"
    }

    func takeStats() -> (sent: Int, dropped: Int, bytes: Int, keyframes: Int, maxSendMs: Double, client: String?) {
        queue.sync {
            defer { stats = (0, 0, 0, 0, 0) }
            return (stats.sent, stats.dropped, stats.bytes, stats.keyframes, stats.maxSendMs, client.map { Self.describe($0.endpoint) })
        }
    }
}
