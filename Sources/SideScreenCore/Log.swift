import Foundation

/// 核心的 log 出口：命令列印到 stdout，App 寫進 ~/Library/Logs
public enum SideScreenLog {
    public static var handler: (String) -> Void = { print($0) }
}

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ msg: String) {
    SideScreenLog.handler("[\(logFormatter.string(from: Date()))] \(msg)")
}

public enum SideScreenError: LocalizedError {
    case displayCreateFailed
    case displayNotFound
    case encoderCreateFailed(OSStatus)
    case portInUse(UInt16)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .displayCreateFailed: "建立虛擬螢幕失敗（是不是已經有另一個 SideScreen 在執行？一次只能開一個）"
        case .displayNotFound: "螢幕擷取找不到虛擬螢幕"
        case .encoderCreateFailed(let s): "建立硬體 H.264 編碼器失敗（\(s)）"
        case .portInUse(let p): "埠 \(p) 已被其他程式占用，請換一個埠"
        case .server(let m): "伺服器錯誤：\(m)"
        }
    }
}

/// 區網 IPv4（只取 en* 介面，排除 loopback、VPN）
public func lanAddresses() -> [String] {
    var out: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
    defer { freeifaddrs(ifap) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        guard String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        out.append(String(cString: host))
    }
    return out
}
