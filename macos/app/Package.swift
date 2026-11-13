// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TuneFree",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TuneFree",
            path: "Sources/TuneFree"
        )
    ]
)
