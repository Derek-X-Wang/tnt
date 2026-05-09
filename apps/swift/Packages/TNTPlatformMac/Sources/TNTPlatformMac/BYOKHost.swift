// BYOKHost — standalone "Replace API Key…" window for the menu-bar
// action. Distinct from `OnboardingHost` because the User has already
// onboarded — the only screen they need is the BYOK form.

import AppKit
import SwiftUI

@MainActor
public final class BYOKHost {

    public typealias Completion = @MainActor () -> Void

    private var window: NSWindow?
    private var coordinator: BYOKCoordinator?
    private let tester: APIKeyTester
    private let onSaved: Completion

    public init(
        tester: APIKeyTester = OpenAIAPIKeyTester(),
        onSaved: @escaping Completion = {}
    ) {
        self.tester = tester
        self.onSaved = onSaved
    }

    public func present() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let coord = BYOKCoordinator(
            tester: tester,
            onSaved: { [weak self] in
                self?.dismiss()
                self?.onSaved()
            }
        )
        self.coordinator = coord

        let view = VStack(alignment: .leading, spacing: 18) {
            Text("Replace OpenAI API key")
                .font(.title2)
                .fontWeight(.semibold)
            BYOKView(coordinator: coord)
        }
        .padding(28)
        .frame(width: 480)

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Replace API Key"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    public func dismiss() {
        window?.close()
        window = nil
        coordinator = nil
    }
}
