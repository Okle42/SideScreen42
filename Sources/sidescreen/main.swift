import Foundation
import SideScreenCore

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options.parse(CommandLine.arguments)
let streamer = MainActor.assumeIsolated { Streamer(config: opts.config) }

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    return "[\(f.string(from: Date()))]"
}

// Ctrl+C / kill：先停擷取、釋放虛擬螢幕再離開
var shuttingDown = false
func shutdown(code: Int32 = 0) {
    if shuttingDown { return }
    shuttingDown = true
    print("\(stamp()) 結束中…")
    Task { @MainActor in
        await streamer.stop()
        exit(code)
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

// 統計：有畫面在送、有丟幀、或每分鐘一次心跳才印，避免整晚洗版
var quietCount = 0
MainActor.assumeIsolated {
streamer.onStats = { s in
    quietCount += 1
    guard s.sendFPS > 0 || s.dropped > 0 || quietCount >= 12 else { return }
    quietCount = 0
    print(String(format: "%@ 擷取 %.1f fps｜送出 %.1f fps｜丟棄 %d｜關鍵幀 %d｜%.2f Mbps｜編碼 %.1f/%.1f ms｜最慢送出 %.0f ms｜%@",
                 stamp(), s.captureFPS, s.sendFPS, s.dropped, s.keyframes, s.mbps, s.encodeAvgMs, s.encodeMaxMs, s.maxSendMs, s.client ?? "等待連線"))
}
streamer.onFatal = { e in
    print("錯誤：\(e.localizedDescription)")
    shutdown(code: 1)
}
}

Task { @MainActor in
    do {
        try await streamer.start()
        for url in streamer.urls { print("➜ 在接收端連線：\(url)") }
        print("（Ctrl+C 結束；虛擬螢幕會一起移除）")
    } catch {
        print("錯誤：\(error.localizedDescription)")
        if !(error is SideScreenError) {
            print("請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」允許目前使用的終端機 App，然後重新執行")
        }
        exit(1)
    }
}

dispatchMain()
