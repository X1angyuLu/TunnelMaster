// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TunnelMaster",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TunnelMaster", targets: ["TunnelMaster"])],
    targets: [
        .target(name: "TunnelMasterCore"),
        .executableTarget(name: "TunnelMaster", dependencies: ["TunnelMasterCore"]),
        .testTarget(name: "TunnelMasterCoreTests", dependencies: ["TunnelMasterCore"]),
    ]
)
