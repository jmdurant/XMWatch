// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XMWatch-watchOS",
    platforms: [
        .watchOS("26.0")
    ],
    dependencies: [
        .package(path: "../StarPlayrRadioKit")
    ],
    targets: [
        .executableTarget(
            name: "XMWatch-watchOS",
            dependencies: [
                .product(name: "StarPlayrRadioKit", package: "StarPlayrRadioKit")
            ],
            path: ".",
            exclude: ["Info.plist", "XMWatch-watchOS.entitlements", "Package.swift", "README.md"]
        )
    ]
)
