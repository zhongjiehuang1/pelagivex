// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PelagiVexNative", platforms: [.macOS(.v14)],
    products: [.executable(name: "PelagiVexNative", targets: ["PelagiVexNative"])],
    targets: [
        .target(name: "VisionCore", dependencies: ["PelagiVexCpp"]),
        .target(name: "PelagiVexCpp"),
        .target(name: "PelagiVexDepth", cxxSettings: [.unsafeFlags(["-fobjc-arc"], .when(platforms: [.macOS]))],
                linkerSettings: [.linkedFramework("CoreML", .when(platforms: [.macOS])),
                                 .linkedFramework("CoreImage", .when(platforms: [.macOS])),
                                 .linkedFramework("CoreVideo", .when(platforms: [.macOS]))]),
        .executableTarget(name: "PelagiVexNative", dependencies: ["VisionCore", "PelagiVexCpp",
            .target(name: "PelagiVexDepth", condition: .when(platforms: [.macOS]))]),
        .testTarget(name: "VisionCoreTests", dependencies: ["VisionCore"])
    ],
    cxxLanguageStandard: .cxx17
)
