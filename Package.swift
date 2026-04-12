// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenPilot",
            path: "Sources/ScreenPilot"
        )
    ]
)
