import CVirtualDisplay
import Foundation

/// 建立並持有虛擬螢幕。物件被釋放時螢幕就會消失。
public final class VirtualDisplay {
    private let display: CGVirtualDisplay
    public var displayID: CGDirectDisplayID { display.displayID }

    public static let modes: [(UInt32, UInt32)] = [(1504, 1003), (1128, 752), (1880, 1253)]

    init(preferredMode: String) throws {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = "SideScreen (Surface)"
        desc.sizeInMillimeters = CGSize(width: 286, height: 190)
        desc.maxPixelsWide = 3008
        desc.maxPixelsHigh = 2006
        // 固定的序號讓 macOS 記住螢幕排列位置
        desc.vendorID = 0x5353
        desc.productID = 0x5346
        desc.serialNum = 0x0001
        desc.terminationHandler = { _, _ in log("虛擬螢幕已被系統終止") }

        guard let d = CGVirtualDisplay(descriptor: desc) else { throw SideScreenError.displayCreateFailed }
        display = d

        var list = Self.modes
        if let idx = list.firstIndex(where: { "\($0.0)x\($0.1)" == preferredMode }) {
            list.insert(list.remove(at: idx), at: 0)
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = list.map { CGVirtualDisplayMode(width: $0.0, height: $0.1, refreshRate: 60) }
        guard display.apply(settings) else { throw SideScreenError.displayCreateFailed }
        log("虛擬螢幕已建立：SideScreen (Surface)，displayID=\(displayID)，模式 \(list[0].0)x\(list[0].1) pt（HiDPI）")
    }
}
