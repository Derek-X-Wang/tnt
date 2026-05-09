// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TNTCore", targets: ["TNTCore"]),
    ],
    targets: [
        .target(name: "TNTCore"),
        .testTarget(
            name: "TNTCoreTests",
            dependencies: ["TNTCore"]
        ),
    ]
)
