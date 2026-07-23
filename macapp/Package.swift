// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Translate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Translate",
            path: "Sources/Translate",
            exclude: ["Resources/Info.plist"]
        )
    ]
)
