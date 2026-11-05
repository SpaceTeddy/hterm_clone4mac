// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hardterm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Hardterm", path: "Sources/Hardterm")
    ]
)
