// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwifterLite",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .watchOS("26.0")
    ],
    products: [
        .library(
            name: "SwifterLite",
            targets: ["SwifterLite"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "SwifterLite",
            dependencies: [])
    ]
)
