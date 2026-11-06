// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "assetdump",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../app/Vendor/AssetKit")],
    targets: [.executableTarget(name: "assetdump", dependencies: [.product(name: "AssetKit", package: "AssetKit")], swiftSettings: [.swiftLanguageMode(.v5)])]
)
