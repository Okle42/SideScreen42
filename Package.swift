// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SideScreen42",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sidescreen", targets: ["sidescreen"]),
        .executable(name: "SideScreen42", targets: ["SideScreen42App"]),
    ],
    targets: [
        // CGVirtualDisplay 是 CoreGraphics 私有 API，這裡只放宣告
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // 共用核心：虛擬螢幕 → 擷取 → 編碼 → WebSocket
        .target(
            name: "SideScreenCore",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/SideScreenCore",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
        // 命令列版
        .executableTarget(
            name: "sidescreen",
            dependencies: ["SideScreenCore"],
            path: "Sources/sidescreen"
        ),
        // 選單列 App（scripts/make-app.sh 打包成 SideScreen42.app）
        .executableTarget(
            name: "SideScreen42App",
            dependencies: ["SideScreenCore"],
            path: "Sources/SideScreen42App",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
    ]
)
