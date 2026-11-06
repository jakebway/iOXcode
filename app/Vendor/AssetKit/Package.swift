// swift-tools-version: 6.0
// Vendored from xtool-org/AssetKit (MIT). Changes: iOS platform, no tests, SVG rasterizer only on macOS.
import PackageDescription

let package = Package(
    name: "AssetKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AssetKit", targets: ["AssetKit"])],
    dependencies: [
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"),
    ],
    targets: [
        .target(name: "CLZFSE", path: "Sources/CLZFSE", exclude: ["LICENSE", "UPSTREAM.md"], publicHeadersPath: "include"),
        .target(name: "AssetKit", dependencies: [.product(name: "PNG", package: "swift-png"), "CLZFSE"]),
    ],
    swiftLanguageModes: [.v6]
)
