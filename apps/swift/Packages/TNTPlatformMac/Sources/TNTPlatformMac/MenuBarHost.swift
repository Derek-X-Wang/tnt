// MenuBarHost — owns the `NSStatusItem` that renders the State Lamp and
// the menu attached to it. Permanent-client per ADR-0003: only the device
// can read OS resources like the menu bar, so this stays a `final class`
// with no protocol layer.
//
// v0 menu surface is intentionally minimal: a non-clickable title row that
// echoes `AppState.menuTitle` and a Quit item. Future milestones (M1 adds
// the Capture Chip; M2 adds Worker Agent presence indicators) bolt onto
// this same `NSStatusItem` rather than introducing additional menu-bar
// surfaces.

import AppKit

@MainActor
public final class MenuBarHost {

    /// The currently displayed State Lamp value. Mutating goes through
    /// `setState(_:)` so icon, tint, and menu title stay in sync.
    public private(set) var state: AppState

    private let statusItem: NSStatusItem
    private let titleMenuItem: NSMenuItem

    /// - Parameter initialState: Starting State Lamp value. v0 launches in
    ///   `.idle`; later milestones may want to restore a remembered state.
    public init(initialState: AppState = .idle) {
        self.state = initialState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.titleMenuItem = NSMenuItem(title: initialState.menuTitle, action: nil, keyEquivalent: "")
        self.titleMenuItem.isEnabled = false

        configureMenu()
        applyState(initialState)
    }

    /// Drive the lamp from outside the class. Idempotent — repeated calls
    /// with the same value are cheap and safe.
    public func setState(_ newState: AppState) {
        guard state != newState else { return }
        state = newState
        applyState(newState)
    }

    // MARK: - Wiring

    private func configureMenu() {
        let menu = NSMenu()
        menu.addItem(titleMenuItem)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "Quit TNT",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

#if DEBUG
        menu.addItem(NSMenuItem.separator())
        menu.addItem(Self.makeDebugStateMenu(target: self))
#endif

        statusItem.menu = menu
    }

    private func applyState(_ state: AppState) {
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: state.symbolName,
                accessibilityDescription: state.menuTitle
            )
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = state.tint.nsColor
        }
        titleMenuItem.title = state.menuTitle
    }

#if DEBUG
    /// Hidden debug submenu that lets engineers flip the State Lamp at
    /// runtime to validate icon + tint + title wiring without producing a
    /// real Voice Turn. Compiled out of release builds.
    private static func makeDebugStateMenu(target: MenuBarHost) -> NSMenuItem {
        let parent = NSMenuItem(title: "Debug: Set state", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Debug: Set state")
        for state in AppState.allCases {
            let item = NSMenuItem(
                title: state.menuTitle,
                action: #selector(DebugStateForwarder.flip(_:)),
                keyEquivalent: ""
            )
            item.representedObject = state
            item.target = DebugStateForwarder.shared(for: target)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// Tiny `@objc`-callable forwarder so `NSMenuItem` selectors can drive
    /// `MenuBarHost.setState(_:)` without leaking `@MainActor` plumbing.
    @MainActor
    private final class DebugStateForwarder: NSObject {
        private static var registry: [ObjectIdentifier: DebugStateForwarder] = [:]
        static func shared(for host: MenuBarHost) -> DebugStateForwarder {
            let id = ObjectIdentifier(host)
            if let existing = registry[id] { return existing }
            let made = DebugStateForwarder(host: host)
            registry[id] = made
            return made
        }

        private weak var host: MenuBarHost?
        private init(host: MenuBarHost) { self.host = host }

        @objc func flip(_ sender: NSMenuItem) {
            guard let next = sender.representedObject as? AppState else { return }
            host?.setState(next)
        }
    }
#endif
}
