// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetrKit",
    platforms: [.macOS("26.0")],
    products: [
        // Plan 01-02 adds MetrCore and MetrSystem to this product.
        .library(name: "MetrKit", targets: ["MetrRender"])
    ],
    targets: [
        // Plan 01-02 makes MetrRender depend on MetrCore.
        .target(name: "MetrRender"),
        .testTarget(name: "MetrRenderTests", dependencies: ["MetrRender"]),
    ],
    swiftLanguageModes: [.v6]
)
