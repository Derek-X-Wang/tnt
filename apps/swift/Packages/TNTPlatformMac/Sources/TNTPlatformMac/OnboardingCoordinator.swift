// OnboardingCoordinator — drives `OnboardingFlow` from SwiftUI button
// presses + async TCC results, and persists `tnt.has_onboarded` once
// the BYOK key has been saved to Keychain. ObservableObject so
// `OnboardingView` re-renders on every step change.

import AppKit
import Combine
import Foundation

@MainActor
public final class OnboardingCoordinator: ObservableObject {

    @Published public private(set) var flow: OnboardingFlow

    public let body: ConsentBody

    /// Exposed so `OnboardingView`'s embedded `BYOKView` can pass the
    /// same tester implementation through to its own coordinator.
    public let apiKeyTester: APIKeyTester

    private let requester: PermissionRequester
    private let defaults: UserDefaults
    private let onComplete: @MainActor () -> Void

    public init(
        body: ConsentBody = .default,
        requester: PermissionRequester = PermissionRequester(),
        apiKeyTester: APIKeyTester = OpenAIAPIKeyTester(),
        defaults: UserDefaults = .standard,
        onComplete: @escaping @MainActor () -> Void
    ) {
        self.body = body
        self.requester = requester
        self.apiKeyTester = apiKeyTester
        self.defaults = defaults
        self.flow = OnboardingFlow()
        self.onComplete = onComplete
    }

    // MARK: - Buttons

    public func continueFromIntro() {
        flow.continueFromIntro()
        Task { await requestMicrophone() }
    }

    public func retryMicrophone() {
        flow.retryMicrophone()
        Task { await requestMicrophone() }
    }

    public func retryInputMonitoring() {
        flow.retryInputMonitoring()
        Task { await requestInputMonitoring() }
    }

    public func openMicrophoneSettings() {
        Self.openSettings(deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public func openInputMonitoringSettings() {
        Self.openSettings(deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    /// Called by `BYOKCoordinator` once the key has been written to
    /// Keychain. Marks the User onboarded and signals completion.
    public func apiKeySaved() {
        flow.apiKeySaved()
        OnboardingFlag.setOnboarded(true, in: defaults)
        onComplete()
    }

    // MARK: - Async TCC

    private func requestMicrophone() async {
        let granted = await requester.requestMicrophone()
        flow.microphoneDecision(granted: granted)
        if granted {
            await requestInputMonitoring()
        }
    }

    private func requestInputMonitoring() async {
        let granted = await requester.requestInputMonitoring()
        flow.inputMonitoringDecision(granted: granted)
        // Onboarded state is set in `apiKeySaved()`, not here — the
        // User must finish the BYOK step before onboarding counts as
        // complete.
    }

    // MARK: - Helpers

    private static func openSettings(deepLink: String) {
        guard let url = URL(string: deepLink) else { return }
        NSWorkspace.shared.open(url)
    }
}
