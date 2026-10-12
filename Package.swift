// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Paper",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(name: "Paper", path: "Sources/Paper")
    ]
)
