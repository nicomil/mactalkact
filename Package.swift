// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTalkAct",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "MacTalkAct",
            path: "Sources/MacTalkAct",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
