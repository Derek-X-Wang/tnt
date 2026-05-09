// TNTiOS — iOS app target stub. v0 is macOS-only (see docs/roadmap.md);
// this target exists so cross-platform Swift Packages stay buildable for
// the iOS slice that activates post-v0. Imports `TNTCore` to validate the
// shared, platform-agnostic side of the workspace from iOS.

import SwiftUI
import TNTCore

@main
struct TNTiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("TNT")
                .font(.largeTitle)
            Text("iOS stub — v0 is macOS-only")
                .foregroundStyle(.secondary)
            Text("Module: \(String(describing: TNTCoreModule.self))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
