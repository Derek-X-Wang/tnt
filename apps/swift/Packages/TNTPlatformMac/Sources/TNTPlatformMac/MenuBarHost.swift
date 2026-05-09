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

    /// Most recent peak dB sample from the mic. Rendered as a small
    /// suffix on the menu title item while the lamp is `.listening`,
    /// so the User can see live VU motion without an extra window.
    public private(set) var micLevelDB: Float?

    /// Last operational error to surface to the User (e.g. invalid
    /// OpenAI key during the M0/S7 WS roundtrip). Rendered as a banner
    /// row in the menu when non-nil.
    public private(set) var lastErrorMessage: String?

    private let statusItem: NSStatusItem
    private let forwarder: MenuActionForwarder

    public init(
        initialState: AppState = .idle,
        permissionStatus: PermissionStatus = .ok,
        onOpenInputMonitoringSettings: MenuAction? = nil,
        onRetryInputMonitoring: MenuAction? = nil,
        onReplaceAPIKey: MenuAction? = nil,
        onTestWSRoundtrip: MenuAction? = nil
    ) {
        self.state = initialState
        self.permissionStatus = permissionStatus
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.forwarder = MenuActionForwarder(
            openSettings: onOpenInputMonitoringSettings,
            retry: onRetryInputMonitoring,
            replaceAPIKey: onReplaceAPIKey,
            testWSRoundtrip: onTestWSRoundtrip,
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

    /// Set or clear the operational error banner.
    public func setLastErrorMessage(_ message: String?) {
        guard lastErrorMessage != message else { return }
        lastErrorMessage = message
        rebuild()
    }

    /// Push a peak dB sample. Pass `nil` to clear (e.g. on `.idle`).
    /// Updates only the menu title text — the icon doesn't redraw, so
    /// the per-frame cadence stays cheap.
    public func setMicLevel(_ dB: Float?) {
        guard micLevelDB != dB else { return }
        micLevelDB = dB
        // Re-render the title item only, not the whole status-item
        // appearance — the icon doesn't depend on level.
        if let menu = statusItem.menu, let title = menu.items.first {
            title.title = renderedMenuTitle()
        }
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

    private func renderedMenuTitle() -> String {
        guard state == .listening, let level = micLevelDB else {
            return state.menuTitle
        }
        return "\(state.menuTitle) · \(Self.formatDB(level))"
    }

    private static func formatDB(_ value: Float) -> String {
        // Clamp so the title doesn't grow with extreme outliers.
        let clamped = max(-99, min(0, Int(value.rounded())))
        return "\(clamped) dB"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: renderedMenuTitle(), action: nil, keyEquivalent: "")
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

        if let error = lastErrorMessage {
            menu.addItem(NSMenuItem.separator())
            let banner = NSMenuItem(title: "⚠ \(error)", action: nil, keyEquivalent: "")
            banner.isEnabled = false
            menu.addItem(banner)
        }

        menu.addItem(NSMenuItem.separator())

        forwarder.attachReplaceAPIKeyItem(into: menu)

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
        forwarder.attachTestWSRoundtripItem(into: menu)
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
    private let replaceAPIKeyAction: MenuBarHost.MenuAction?
    private let testWSRoundtripAction: MenuBarHost.MenuAction?
    var setStateAction: ((AppState) -> Void)?

    init(
        openSettings: MenuBarHost.MenuAction?,
        retry: MenuBarHost.MenuAction?,
        replaceAPIKey: MenuBarHost.MenuAction?,
        testWSRoundtrip: MenuBarHost.MenuAction?,
        setState: ((AppState) -> Void)?
    ) {
        self.openSettingsAction = openSettings
        self.retryAction = retry
        self.replaceAPIKeyAction = replaceAPIKey
        self.testWSRoundtripAction = testWSRoundtrip
        self.setStateAction = setState
    }

    func attachReplaceAPIKeyItem(into menu: NSMenu) {
        guard replaceAPIKeyAction != nil else { return }
        let item = NSMenuItem(
            title: "Replace API Key…",
            action: #selector(replaceAPIKey(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func replaceAPIKey(_ sender: NSMenuItem) {
        replaceAPIKeyAction?()
    }

#if DEBUG
    func attachTestWSRoundtripItem(into menu: NSMenu) {
        guard testWSRoundtripAction != nil else { return }
        let item = NSMenuItem(
            title: "Test WS Roundtrip",
            action: #selector(testWSRoundtrip(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func testWSRoundtrip(_ sender: NSMenuItem) {
        testWSRoundtripAction?()
    }
#endif

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
