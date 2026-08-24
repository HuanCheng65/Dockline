// swift-tools-version: 6.0
import PackageDescription

let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Dockline",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0")],   // Liquid Glass（计划书 §3.1）——本项目已放弃 App Store 分发，不构成约束
    targets: [
        // 窗口索引、私有符号封装、召回路径——bar 与诊断 CLI 共用同一份实现
        .target(name: "DocklineCore", path: "Sources/DocklineCore", swiftSettings: mode),
        // M0/M0.5 的诊断工具，保留
        .executableTarget(name: "docklinespike", dependencies: ["DocklineCore"],
                          path: "Sources/docklinespike", swiftSettings: mode),
        // 活动状态的上报入口（计划书 §3），随 App 一起装进 bundle
        .executableTarget(name: "dockctl", path: "Sources/dockctl", swiftSettings: mode),
        // M1 起的正式 App
        .executableTarget(name: "Dockline", dependencies: ["DocklineCore"],
                          path: "Sources/Dockline",
                          resources: [.process("Resources")],
                          swiftSettings: mode),
    ]
)
