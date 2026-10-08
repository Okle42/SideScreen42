// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SideScreen42",
    platforms: [.macOS(.v14)],
    targets: [
        // CGVirtualDisplay 是 CoreGraphics 私有 API，這裡只放宣告
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "sidescreen",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/sidescreen",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
