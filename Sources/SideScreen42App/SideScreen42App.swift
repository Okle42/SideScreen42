import AppKit
import ServiceManagement
import SideScreenCore
import SwiftUI

@main
struct SideScreen42App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }

        Settings {
            SettingsView(model: delegate.model, showMenuBarExtra: $showMenuBarExtra)
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    var body: some View {
        // 狀態用換形狀表達（template 圖示會被系統重新上色，不能靠顏色）
        Image(systemName: model.symbolName)
            .accessibilityLabel("SideScreen42：\(model.statusText)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if model.shareAtLaunch { model.start() }
    }

    /// 從 Finder／Spotlight 再打開時（選單列圖示可能被藏起來），打開設定讓人找得到開關與結束
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        return true
    }

    /// 結束前先停分享，虛擬螢幕會乾淨移除
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isSharing else { return .terminateNow }
        Task {
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusText)
        if let detail = model.detailText {
            Text(detail).monospacedDigit()
        }
        if model.needsScreenRecording {
            Button("打開「螢幕與系統錄音」設定⋯") { model.openScreenRecordingSettings() }
        }

        Divider()

        Button(model.isSharing ? "停止分享" : "開始分享") { model.toggle() }
        if model.isSharing, let url = model.urls.first {
            Button("拷貝接收網址（\(url)）") { model.copyURL() }
        }
        Button("在Finder中顯示接收網頁") { model.revealReceiver() }

        Divider()

        Button("關於SideScreen42") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: NSAttributedString(string: "把有瀏覽器的筆電變成 Mac 的無線延伸螢幕\ngithub.com/Okle42/SideScreen42"),
            ])
        }
        Button("設定⋯") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("結束SideScreen42") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var showMenuBarExtra: Bool

    private let bitrates: [Double] = [6, 8, 12, 20]
    private let modes: [(String, String)] = [
        ("1504x1003", "1504×1003（預設，跟Windows 150%一樣大）"),
        ("1128x752", "1128×752（像素一比一，最銳利）"),
        ("1880x1253", "1880×1253（空間最大，字最小）"),
    ]

    var body: some View {
        Form {
            Section("一般") {
                Toggle("在登入時打開", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                if model.loginItemStatus == .requiresApproval {
                    LabeledContent("需要在系統設定中允許") {
                        Button("打開登入項目設定⋯") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("打開App時自動開始分享", isOn: $model.shareAtLaunch)
                Toggle("在選單列中顯示", isOn: $showMenuBarExtra)
            }
            Section {
                Picker("解析度", selection: $model.mode) {
                    ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("碼率", selection: $model.bitrateMbps) {
                    ForEach(bitrates, id: \.self) { Text("\(Int($0)) Mbps").tag($0) }
                }
                TextField("埠", value: $model.port, format: .number.grouping(.never))
                    .monospacedDigit()
            } header: {
                Text("串流")
            } footer: {
                Text("改了會立刻重新開始分享。接收端會自動重連。")
                    .foregroundStyle(.secondary)
            }
            Section("記錄") {
                LabeledContent("記錄檔") {
                    Button("在Finder中顯示") { model.revealLog() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.mode) { model.applySettings() }
        .onChange(of: model.bitrateMbps) { model.applySettings() }
        .onChange(of: model.port) { model.applySettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
        }
    }
}
