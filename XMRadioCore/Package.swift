// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XMRadioCore",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "XMRadioCore", targets: ["XMRadioCore"])],
    targets: [
        .target(name: "XMRadioCore"),
        .testTarget(name: "XMRadioCoreTests", dependencies: ["XMRadioCore"])
    ]
)
