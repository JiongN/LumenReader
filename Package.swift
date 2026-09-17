// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumenReader",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lumen", targets: ["LumenApp"])
    ],
    targets: [
        // 核心引擎层：解析、AI、检索、OCR、TTS。不依赖 SwiftUI，可独立测试。
        .target(
            name: "LumenKit",
            path: "Sources/LumenKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 界面层：SwiftUI。
        .executableTarget(
            name: "LumenApp",
            dependencies: ["LumenKit"],
            path: "Sources/LumenApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
