// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TunnelMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TunnelMenu", targets: ["TunnelMenu"])],
    targets: [
        .target(name: "TunnelMenuCore"),
        .executableTarget(name: "TunnelMenu", dependencies: ["TunnelMenuCore"]),
        .testTarget(name: "TunnelMenuCoreTests", dependencies: ["TunnelMenuCore"]),
    ]
)
