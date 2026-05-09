// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTCognitive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TNTCognitive", targets: ["TNTCognitive"]),
    ],
    targets: [
        .target(name: "TNTCognitive"),
    ]
)
