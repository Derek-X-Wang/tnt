// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTRealtime",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TNTRealtime", targets: ["TNTRealtime"]),
    ],
    targets: [
        .target(name: "TNTRealtime"),
    ]
)
