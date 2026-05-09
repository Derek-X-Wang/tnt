// TNTMac — the Desktop App that owns mic, hotkeys, TTS, UI, local memory,
// BYOK config, the WebSocket to OpenAI Realtime, and the Local Ingest port.
// One process per User (v0 is single-tenant by design — see CONTEXT.md).

import SwiftUI

// Imports below verify each Swift Package wires into the app target. They
// are intentionally referenced (not just imported) so the linker keeps them
// in the binary and any package compile-error surfaces in the TNTMac build.
import TNTCore
import TNTRealtime
import TNTCognitive
import TNTMemory
import TNTIngest
import TNTPlatformMac

@main
struct TNTMacApp: App {
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
            Text("Personal Master Agent — workspace skeleton")
                .foregroundStyle(.secondary)
            Text(Self.modulesLoaded)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(minWidth: 320, minHeight: 200)
    }

    /// Forces every linked package module to participate in the binary so
    /// missing-symbol regressions surface at app build time, not later.
    static let modulesLoaded: String = {
        _ = TNTCoreModule.self
        _ = TNTRealtimeModule.self
        _ = TNTCognitiveModule.self
        _ = TNTMemoryModule.self
        _ = TNTIngestModule.self
        _ = TNTPlatformMacModule.self
        return "modules linked: Core, Realtime, Cognitive, Memory, Ingest, PlatformMac"
    }()
}
