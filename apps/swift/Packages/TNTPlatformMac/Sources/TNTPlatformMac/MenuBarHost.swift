// MenuBarHost — owns the `NSStatusItem` that renders the State Lamp and
// the menu attached to it. Permanent-client per ADR-0003: only the device
// can read OS resources like the menu bar, so this stays a `final class`
// with no protocol layer.
//
// v0 menu surface is intentionally minimal: a non-clickable title row
// echoing `AppState.menuTitle`, an optional Input-Monitoring permission
// banner, and a Quit item. M1 attaches the Capture Chip popover to the
// same `NSStatusItem`; M2 layers Worker Agent presence indicators.

import AppKit

@MainActor
public final class MenuBarHost {

    public typealias MenuAction = @MainActor () -> Void

    /// Permission state surfaced through the menu. The banner only
    /// appears when something is wrong — `.ok` keeps the menu clean.
    public enum PermissionStatus: Sendable, Equatable {
        case ok
        case inputMonitoringRequired
    }

    /// The currently displayed State Lamp value. Mutating goes through
    /// `setState(_:)` so icon, tint, and menu title stay in sync.
    public private(set) var state: AppState

    /// Whether the menu currently surfaces a permission warning.
    public private(set) var permissionStatus: PermissionStatus

    private let statusItem: NSStatusItem
    private let forwarder: MenuActionForwarder

    public init(
        initialState: AppState = .idle,
        permissionStatus: PermissionStatus = .ok,
        onOpenInputMonitoringSettings: MenuAction? = nil,
        onRetryInputMonitoring: MenuAction? = nil
    ) {
        self.state = initialState
        self.permissionStatus = permissionStatus
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.forwarder = MenuActionForwarder(
            openSettings: onOpenInputMonitoringSettings,
            retry: onRetryInputMonitoring,
            setState: nil
        )
        // Wire the debug-only state flipper after init so the closure can
        // capture `self` without a retain cycle.
        forwarder.setStateAction = { [weak self] newState in
            self?.setState(newState)
        }

        rebuild()
    }

    /// Drive the lamp from outside the class. Idempotent — repeated
    /// calls with the same value are cheap and safe.
    public func setState(_ newState: AppState) {
        guard state != newState else { return }
        state = newState
        rebuild()
    }

    /// Show or clear the Input Monitoring permission banner.
    public func setPermissionStatus(_ newStatus: PermissionStatus) {
        guard permissionStatus != newStatus else { return }
        permissionStatus = newStatus
        rebuild()
    }

    // MARK: - Wiring

    private func rebuild() {
        applyStatusItemAppearance()
        statusItem.menu = makeMenu()
    }

    private func applyStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: state.symbolName,
            accessibilityDescription: state.menuTitle
        )
        image?.isTemplate = false
        button.image = image
        button.contentTintColor = state.tint.nsColor
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: state.menuTitle, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if permissionStatus == .inputMonitoringRequired {
            menu.addItem(NSMenuItem.separator())

            // Wording matches the M0/S3 acceptance criterion verbatim.
            // The specific permission name (Input Monitoring) lives on
            // the Open Settings deep-link target, not on the banner row.
            let banner = NSMenuItem(title: "Permissions required", action: nil, keyEquivalent: "")
            banner.isEnabled = false
            menu.addItem(banner)

            forwarder.attachOpenSettingsItem(into: menu)
            forwarder.attachRetryItem(into: menu)
        }

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
        menu.addItem(forwarder.makeDebugStateMenuItem())
#endif

        return menu
    }
}

/// `@objc`-callable bridge so `NSMenuItem` selectors can drive the host
/// without leaking `@MainActor` plumbing into AppKit's selector ABI. One
/// instance per `MenuBarHost`.
@MainActor
private final class MenuActionForwarder: NSObject {

    private let openSettingsAction: MenuBarHost.MenuAction?
    private let retryAction: MenuBarHost.MenuAction?
    var setStateAction: ((AppState) -> Void)?

    init(
        openSettings: MenuBarHost.MenuAction?,
        retry: MenuBarHost.MenuAction?,
        setState: ((AppState) -> Void)?
    ) {
        self.openSettingsAction = openSettings
        self.retryAction = retry
        self.setStateAction = setState
    }

    func attachOpenSettingsItem(into menu: NSMenu) {
        guard openSettingsAction != nil else { return }
        let item = NSMenuItem(
            title: "Open Settings",
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    func attachRetryItem(into menu: NSMenu) {
        guard retryAction != nil else { return }
        let item = NSMenuItem(
            title: "Retry",
            action: #selector(retry(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        openSettingsAction?()
    }

    @objc func retry(_ sender: NSMenuItem) {
        retryAction?()
    }

#if DEBUG
    func makeDebugStateMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Debug: Set state", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Debug: Set state")
        for state in AppState.allCases {
            let item = NSMenuItem(
                title: state.menuTitle,
                action: #selector(flipDebugState(_:)),
                keyEquivalent: ""
            )
            item.representedObject = state
            item.target = self
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc func flipDebugState(_ sender: NSMenuItem) {
        guard let next = sender.representedObject as? AppState else { return }
        setStateAction?(next)
    }
#endif
}
