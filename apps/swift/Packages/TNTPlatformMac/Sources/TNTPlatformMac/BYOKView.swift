// BYOKView — the API-key entry form shared by the first-run onboarding
// flow and the menu-bar "Replace API Key…" action. Pure SwiftUI
// reading from a `BYOKCoordinator`.

import SwiftUI

public struct BYOKView: View {

    @ObservedObject private var coordinator: BYOKCoordinator

    public init(coordinator: BYOKCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect OpenAI")
                .font(.headline)
            Text("Paste your OpenAI API key. TNT stores it in the macOS Keychain — never on disk in plaintext.")
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("sk-…", text: $coordinator.key)
                .textFieldStyle(.roundedBorder)
                .onSubmit { coordinator.runTest() }

            HStack(spacing: 8) {
                Button("Test") { coordinator.runTest() }
                    .disabled(coordinator.testStatus == .testing)
                Button("Save") { coordinator.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canSave)
                Spacer()
                statusLabel
            }

            if let error = coordinator.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch coordinator.testStatus {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary).font(.caption)
            }
        case .success:
            Text("✓ Key works")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}
