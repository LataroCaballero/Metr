// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetrKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MetrKit", targets: ["MetrCore", "MetrSystem", "MetrRender"])
    ],
    targets: [
        .target(name: "MetrCore"),
        .target(name: "MetrSystem", dependencies: ["MetrCore"]),
        .target(name: "MetrRender", dependencies: ["MetrCore"]),
        .testTarget(name: "MetrCoreTests", dependencies: ["MetrCore"]),
        .testTarget(name: "MetrRenderTests", dependencies: ["MetrRender"]),
    ],
    swiftLanguageModes: [.v6]
)
