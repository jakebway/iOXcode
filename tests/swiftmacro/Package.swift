// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StringifyDemo",
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")],
    targets: [
        .executableTarget(name: "StringifyMacros", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ]),
    ]
)
