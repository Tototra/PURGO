// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Purgo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Purgo",
            path: "Sources/Purgo"
        )
    ]
)
