// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTMemory",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TNTMemory", targets: ["TNTMemory"]),
    ],
    targets: [
        .target(name: "TNTMemory"),
    ]
)
