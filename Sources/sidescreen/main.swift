import CoreMedia
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options.parse(CommandLine.arguments)

// 區網 IP（排除 loopback、VPN 介面）
func lanAddresses() -> [String] {
    var out: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
    defer { freeifaddrs(ifap) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ifa.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        out.append(String(cString: host))
    }
    return out
}

var display: VirtualDisplay? = VirtualDisplay(preferredMode: opts.mode)
let encoder = Encoder(width: opts.width, height: opts.height, fps: opts.fps, bitrateMbps: opts.bitrateMbps)
let capture = Capture(encoder: encoder)
let server = Server(port: opts.port)

var dumpHandle: FileHandle?
if let path = opts.dumpPath {
    FileManager.default.createFile(atPath: path, contents: nil)
    dumpHandle = FileHandle(forWritingAtPath: path)
    if dumpHandle == nil { fail("無法寫入 \(path)") }
    log("同時輸出到 \(path)（ffplay \(path) 可播放）")
}

encoder.onFrame = { f in
    dumpHandle?.write(f.annexB)
    server.send(f, width: opts.width, height: opts.height, fps: opts.fps)
}
server.onKeyframeRequest = { capture.keyframeNow() }
// 錄檔模式一律全速；否則沒人連線就待機
server.onClientChange = { connected in capture.setActive(connected || dumpHandle != nil) }
server.start()

for ip in lanAddresses() {
    print("➜ 在 Surface 上連線：ws://\(ip):\(opts.port)/stream")
}
print("（Ctrl+C 結束；虛擬螢幕會一起移除）")

// Ctrl+C / kill：先停擷取、釋放虛擬螢幕再離開
var shuttingDown = false
func shutdown() {
    if shuttingDown { return }
    shuttingDown = true
    log("結束中…")
    Task {
        await capture.stop()
        encoder.invalidate()
        server.stop()
        try? dumpHandle?.close()
        DispatchQueue.main.async {
            display = nil
            log("虛擬螢幕已移除")
            exit(0)
        }
    }
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { shutdown() }
    src.resume()
    signalSources.append(src)
}

Task {
    do {
        try await capture.start(displayID: display!.displayID, width: opts.width, height: opts.height, fps: opts.fps)
        if dumpHandle == nil && !server.hasClient { capture.setActive(false) }
    } catch {
        log("無法擷取螢幕：\(error.localizedDescription)")
        log("請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」允許目前使用的終端機 App，然後重新執行")
        shutdown()
    }
}

// 每 5 秒印一次統計
let statTimer = DispatchSource.makeTimerSource(queue: .main)
statTimer.schedule(deadline: .now() + 5, repeating: 5)
statTimer.setEventHandler {
    let cap = capture.takeFrameCount()
    let s = server.takeStats()
    let mbps = Double(s.bytes) * 8 / 5 / 1_000_000
    log(String(format: "擷取 %.1f fps｜送出 %.1f fps｜丟棄 %d｜%.2f Mbps｜%@",
               Double(cap) / 5, Double(s.sent) / 5, s.dropped, mbps, s.connected ? "已連線" : "等待連線"))
}
statTimer.resume()

dispatchMain()
