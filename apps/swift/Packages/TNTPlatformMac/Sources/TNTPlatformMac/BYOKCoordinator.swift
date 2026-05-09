// BYOKCoordinator — drives the "Connect OpenAI" form. Owns the entered
// key, the test result, and persists the key into the Keychain via
// `TNTCredentials` on Save.
//
// Lives in its own type (rather than as state inside `OnboardingCoordinator`)
// so the menu-bar "Replace API Key…" flow can reuse the same form by
// instantiating a fresh `BYOKCoordinator` and routing `onSaved` to a
// dismissal of the standalone `BYOKHost` window.

import Combine
import Foundation
import TNTCore

@MainActor
public final class BYOKCoordinator: ObservableObject {

    public enum TestStatus: Sendable, Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @Published public var key: String = ""
    @Published public private(set) var testStatus: TestStatus = .idle
    @Published public private(set) var saveError: String?

    private let tester: APIKeyTester
    private let service: String
    private let onSaved: @MainActor () -> Void

    public init(
        tester: APIKeyTester,
        service: String = TNTCredentials.defaultService,
        onSaved: @escaping @MainActor () -> Void
    ) {
        self.tester = tester
        self.service = service
        self.onSaved = onSaved
    }

    public var canSave: Bool {
        switch testStatus {
        case .success: return true
        default: return false
        }
    }

    public func runTest() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            testStatus = .failure("Enter a key first.")
            return
        }
        testStatus = .testing
        Task { [tester] in
            let result = await tester.test(key: trimmed)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.testStatus = .success
                case .failure(let error):
                    self.testStatus = .failure(Self.describe(error))
                }
            }
        }
    }

    public func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave else {
            saveError = "Test the key first."
            return
        }
        do {
            try TNTCredentials.setOpenAIKey(trimmed, service: service)
            saveError = nil
            onSaved()
        } catch {
            saveError = "Could not save to Keychain: \(error.localizedDescription)"
        }
    }

    private static func describe(_ error: APIKeyTestError) -> String {
        switch error {
        case .invalidKey:           return "OpenAI rejected this key (HTTP 401)."
        case .rateLimited:          return "Rate-limited by OpenAI (HTTP 429). Try again in a few seconds."
        case .network(let detail):  return "Network error: \(detail)"
        case .unexpectedStatus(let code): return "Unexpected response (HTTP \(code))."
        }
    }
}
