// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTPlatformMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TNTPlatformMac", targets: ["TNTPlatformMac"]),
    ],
    dependencies: [
        // Local sibling package — depend by relative path so the
        // workspace stays buildable without a registry / lockfile.
        .package(path: "../TNTCore"),
    ],
    targets: [
        .target(
            name: "TNTPlatformMac",
            dependencies: ["TNTCore"]
        ),
        .testTarget(
            name: "TNTPlatformMacTests",
            dependencies: ["TNTPlatformMac"]
        ),
    ]
)
