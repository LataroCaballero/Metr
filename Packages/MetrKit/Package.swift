// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetrKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MetrKit", targets: ["MetrCore", "MetrSystem", "MetrRender"]),
        // Dev-only CLI used by scripts/verify. The app never links it.
        .executable(name: "metr-probe", targets: ["MetrProbe"]),
    ],
    targets: [
        .target(name: "MetrCore"),
        .target(name: "MetrSystem", dependencies: ["MetrCore"]),
        .target(name: "MetrRender", dependencies: ["MetrCore"]),
        .executableTarget(name: "MetrProbe", dependencies: ["MetrSystem", "MetrCore"]),
        .testTarget(name: "MetrCoreTests", dependencies: ["MetrCore"]),
        .testTarget(name: "MetrSystemTests", dependencies: ["MetrSystem", "MetrCore"]),
        .testTarget(name: "MetrRenderTests", dependencies: ["MetrRender"]),
    ],
    swiftLanguageModes: [.v6]
)
