import Foundation

struct Options {
    var port: UInt16 = 8765
    var bitrateMbps: Double = 12
    var fps: Int = 60
    var dumpPath: String?
    var mode = "1504x1003"          // 虛擬螢幕預設模式（point）
    var width = 2256                // 編碼輸出像素（Surface 實體解析度）
    var height = 1504

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func next() -> String {
            i += 1
            guard i < args.count else { fail("參數 \(args[i - 1]) 缺少值") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--port": o.port = UInt16(next()) ?? o.port
            case "--bitrate": o.bitrateMbps = Double(next()) ?? o.bitrateMbps
            case "--fps": o.fps = Int(next()) ?? o.fps
            case "--dump": o.dumpPath = next()
            case "--mode": o.mode = next()
            case "-h", "--help":
                print("""
                用法：sidescreen [--port 8765] [--bitrate 12] [--fps 60] [--mode 1504x1003] [--dump out.h264]
                  --bitrate  平均位元率（Mbps）
                  --mode     虛擬螢幕預設模式（point）：1504x1003｜1128x752｜1880x1253
                  --dump     同時把 Annex B 串流寫到檔案（可用 ffplay 播放）
                """)
                exit(0)
            default: fail("看不懂的參數：\(args[i])")
            }
            i += 1
        }
        return o
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("錯誤：" + msg + "\n").data(using: .utf8)!)
    exit(1)
}

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ msg: String) {
    print("[\(logFormatter.string(from: Date()))] \(msg)")
}
