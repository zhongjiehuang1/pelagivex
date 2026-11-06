// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PelagiVexNative", platforms: [.macOS(.v14)],
    products: [.executable(name: "PelagiVexNative", targets: ["PelagiVexNative"])],
    targets: [
        .target(name: "VisionCore"),
        .executableTarget(name: "PelagiVexNative", dependencies: ["VisionCore"]),
        .testTarget(name: "VisionCoreTests", dependencies: ["VisionCore"])
    ]
)
