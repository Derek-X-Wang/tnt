// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TNTCognitive",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TNTCognitive", targets: ["TNTCognitive"]),
    ],
    dependencies: [
        // TNTCore provides AgentRef, CaptureSet, AppConfig — the data
        // shapes the Cognitive Engine works with. Per ADR-0003, this
        // package sits on the server-future side of the Future Server
        // Boundary (behind the CognitiveEngine protocol) while its
        // input/output types are in the permanent-client TNTCore.
        .package(path: "../TNTCore"),
    ],
    targets: [
        .target(
            name: "TNTCognitive",
            dependencies: ["TNTCore"]
        ),
        .testTarget(
            name: "TNTCognitiveTests",
            dependencies: ["TNTCognitive"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
