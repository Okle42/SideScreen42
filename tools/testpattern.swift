// 在 SideScreen 虛擬螢幕上開一個 60fps 測試圖視窗（移動色條＋毫秒時鐘），跑完自動關閉
// 用法：swift tools/testpattern.swift [秒數]
import AppKit

let secs = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first(where: { $0.localizedName.contains("SideScreen") }) else {
    print("找不到 SideScreen 虛擬螢幕，請先執行 sidescreen"); exit(1)
}

final class Pattern: NSView {
    var frameNo = 0
    let start = CACurrentMediaTime()
    override func draw(_ r: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let w = bounds.width, h = bounds.height
        // 每幀移動 1/120 寬的色條
        let x = CGFloat(frameNo % 120) / 120 * w
        NSColor.systemGreen.setFill(); NSRect(x: x, y: 0, width: w / 30, height: h).fill()
        // 60 格閃爍方塊：哪一格亮代表第幾幀，拍照時可數掉幀
        for i in 0..<60 {
            (i == frameNo % 60 ? NSColor.white : NSColor.darkGray).setFill()
            NSRect(x: 40 + CGFloat(i) * (w - 80) / 60, y: h - 120, width: (w - 80) / 60 - 4, height: 60).fill()
        }
        let t = CACurrentMediaTime() - start
        let s = String(format: "%07.3f s   #%05d", t, frameNo)
        (s as NSString).draw(at: NSPoint(x: 60, y: h / 2 - 60), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 120, weight: .bold),
            .foregroundColor: NSColor.white])
    }
}

let view = Pattern(frame: screen.frame)
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.contentView = view
win.level = .floating
win.setFrame(screen.frame, display: true)
win.orderFrontRegardless()

let link = screen.displayLink(target: view, selector: #selector(NSView.tick))
link.add(to: .main, forMode: .common)
extension NSView {
    @objc func tick() { if let p = self as? Pattern { p.frameNo += 1; p.needsDisplay = true } }
}
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { win.orderOut(nil); print("測試圖結束，共 \(view.frameNo) 幀"); exit(0) }
print("測試圖顯示在 \(screen.localizedName)，\(Int(secs)) 秒")
app.run()
