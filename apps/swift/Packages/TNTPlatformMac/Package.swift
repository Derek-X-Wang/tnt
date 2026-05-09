// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTPlatformMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TNTPlatformMac", targets: ["TNTPlatformMac"]),
    ],
    targets: [
        .target(name: "TNTPlatformMac"),
    ]
)
