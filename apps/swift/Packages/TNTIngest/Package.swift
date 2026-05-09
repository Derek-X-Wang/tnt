// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTIngest",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TNTIngest", targets: ["TNTIngest"]),
    ],
    targets: [
        .target(name: "TNTIngest"),
    ]
)
