// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WinV",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WinV", path: "Sources/WinV")
    ]
)
