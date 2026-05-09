// OnboardingHost — opens the one-shot first-run consent window for an
// LSUIElement (menu-bar-only) app. Bringing up an `NSWindow` from a no-
// dock app is the documented path for showing onboarding without
// promoting TNT into the app switcher. The window is `.floating` so it
// stays on top of whatever the User had focused when launching TNT.

import AppKit
import SwiftUI

@MainActor
public final class OnboardingHost {

    public typealias Completion = @MainActor () -> Void

    private var window: NSWindow?
    private var coordinator: OnboardingCoordinator?
    private let defaults: UserDefaults
    private let requester: PermissionRequester
    private let onComplete: Completion

    public init(
        defaults: UserDefaults = .standard,
        requester: PermissionRequester = PermissionRequester(),
        onComplete: @escaping Completion
    ) {
        self.defaults = defaults
        self.requester = requester
        self.onComplete = onComplete
    }

    public func present() {
        guard window == nil else { return }

        let coordinator = OnboardingCoordinator(
            requester: requester,
            defaults: defaults,
            onComplete: { [weak self] in
                self?.dismiss()
                self?.onComplete()
            }
        )
        self.coordinator = coordinator

        let hosting = NSHostingController(rootView: OnboardingView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to TNT"
        window.styleMask = [.titled, .closable, .miniaturizable]
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
