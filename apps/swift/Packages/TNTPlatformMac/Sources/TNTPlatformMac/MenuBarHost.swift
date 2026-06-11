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
import TNTCore

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

    /// The Capture Set currently attached to the next Voice Turn,
    /// rendered as the **Capture Chip** (issue #52). Display strings come
    /// from the pure `CaptureChipViewModel` (#81); the raw set is kept for
    /// the preview rows (window title, selection snippet, workspace path).
    public private(set) var attachedCapture: CaptureSet = .empty

    private let statusItem: NSStatusItem
    private let forwarder: MenuActionForwarder

    public init(
        initialState: AppState = .idle,
        permissionStatus: PermissionStatus = .ok,
        onOpenInputMonitoringSettings: MenuAction? = nil,
        onRetryInputMonitoring: MenuAction? = nil,
        onReplaceAPIKey: MenuAction? = nil,
        onTestWSRoundtrip: MenuAction? = nil,
        onCheckForUpdates: MenuAction? = nil,
        onClearContext: MenuAction? = nil,
        onClearLastAppshot: MenuAction? = nil
    ) {
        self.state = initialState
        self.permissionStatus = permissionStatus
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.forwarder = MenuActionForwarder(
            openSettings: onOpenInputMonitoringSettings,
            retry: onRetryInputMonitoring,
            replaceAPIKey: onReplaceAPIKey,
            testWSRoundtrip: onTestWSRoundtrip,
            checkForUpdates: onCheckForUpdates,
            clearContext: onClearContext,
            clearLastAppshot: onClearLastAppshot,
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

    /// Push the Capture Set attached to the next Voice Turn so the
    /// Capture Chip reflects it. Pass `.empty` to show the no-context state.
    public func setCaptureSet(_ capture: CaptureSet) {
        guard attachedCapture != capture else { return }
        attachedCapture = capture
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

        appendCaptureChip(into: menu)

        menu.addItem(NSMenuItem.separator())

        forwarder.attachReplaceAPIKeyItem(into: menu)
        forwarder.attachCheckForUpdatesItem(into: menu)

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
        forwarder.attachDebugSampleContextItem(into: menu)
#endif

        return menu
    }

#if DEBUG
    /// DEBUG-only hook so the Capture Chip's preview + clear paths can be
    /// dogfooded before live AX capture (#49) exists. Set by the app delegate
    /// to push a sample CaptureSet through the same controller path the real
    /// capture will use.
    public var debugAttachSampleContext: MenuAction? {
        get { forwarder.debugSampleContextAction }
        set {
            forwarder.debugSampleContextAction = newValue
            // The menu was built at init, before the app delegate assigns this
            // closure — rebuild so the debug item's nil-guard re-evaluates.
            rebuild()
        }
    }
#endif

    /// The **Capture Chip** section (issue #52): one summary row (via the
    /// pure #81 view-model), a preview submenu exposing exactly what will be
    /// sent (privacy-visibility surface per CONTEXT.md), and a Clear action.
    /// Empty state renders the "No context" row with no actions.
    private func appendCaptureChip(into menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let viewModel = CaptureChipViewModel(capture: attachedCapture)
        let chipRow = NSMenuItem(title: "📎 \(viewModel.summary)", action: nil, keyEquivalent: "")
        chipRow.isEnabled = false

        if !viewModel.isEmpty {
            // Preview: the user sees exactly what's about to be attached
            // BEFORE speaking — this pre-send visibility is what makes
            // capture privacy-defensible (CONTEXT.md → Capture Chip).
            let preview = NSMenu(title: "Context preview")
            if let app = attachedCapture.appName {
                preview.addItem(Self.previewRow("App: \(app)"))
            }
            if let title = attachedCapture.windowTitle {
                preview.addItem(Self.previewRow("Window: \(Self.truncate(title))"))
            }
            if let selection = attachedCapture.selectedText, !selection.isEmpty {
                preview.addItem(Self.previewRow("Selection: \(Self.truncate(selection))"))
            }
            if let project = attachedCapture.project {
                preview.addItem(Self.previewRow("Project: \(project.name)"))
                if let path = project.path {
                    preview.addItem(Self.previewRow("Workspace: \(Self.truncate(path))"))
                }
            }
            chipRow.submenu = preview
            chipRow.isEnabled = true
        }
        menu.addItem(chipRow)

        // Armed Appshots (M4a, #34): one row per appshot with a preview
        // submenu (source app, window title, Window-Text snippet) — the
        // ADR-0004 pre-send visibility surface for screen content.
        for row in viewModel.appshotPreviewRows {
            let item = NSMenuItem(title: "📸 \(row.appName)", action: nil, keyEquivalent: "")
            let preview = NSMenu(title: "Appshot preview")
            preview.addItem(Self.previewRow("App: \(row.appName)"))
            if !row.windowTitle.isEmpty {
                preview.addItem(Self.previewRow("Window: \(Self.truncate(row.windowTitle))"))
            }
            preview.addItem(Self.previewRow(row.windowTextSnippet.isEmpty
                ? "Window Text: (none — text tier will report empty)"
                : "Text: \(Self.truncate(row.windowTextSnippet))"))
            if let data = row.imageJPEG, let image = NSImage(data: data) {
                // M4b (#128): thumbnail preview — the ADR-0004 pre-send
                // visibility surface now covers the image tier too.
                let thumb = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let maxWidth: CGFloat = 220
                let scale = min(1, maxWidth / max(image.size.width, 1))
                image.size = NSSize(width: image.size.width * scale,
                                    height: image.size.height * scale)
                thumb.image = image
                preview.addItem(thumb)
            } else {
                preview.addItem(Self.previewRow("Image: none (text tier)"))
            }
            item.submenu = preview
            menu.addItem(item)
        }

        if !viewModel.isEmpty {
            forwarder.attachClearContextItem(into: menu)
            if !viewModel.appshotPreviewRows.isEmpty {
                forwarder.attachClearLastAppshotItem(into: menu)
            }
        }
    }

    private static func previewRow(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Keep preview rows readable — menu items shouldn't wrap or run wide.
    private static func truncate(_ text: String, max: Int = 60) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > max else { return flattened }
        return String(flattened.prefix(max)) + "…"
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
    private let checkForUpdatesAction: MenuBarHost.MenuAction?
    private let clearContextAction: MenuBarHost.MenuAction?
    private let clearLastAppshotAction: MenuBarHost.MenuAction?
    var setStateAction: ((AppState) -> Void)?

    init(
        openSettings: MenuBarHost.MenuAction?,
        retry: MenuBarHost.MenuAction?,
        replaceAPIKey: MenuBarHost.MenuAction?,
        testWSRoundtrip: MenuBarHost.MenuAction?,
        checkForUpdates: MenuBarHost.MenuAction?,
        clearContext: MenuBarHost.MenuAction?,
        clearLastAppshot: MenuBarHost.MenuAction?,
        setState: ((AppState) -> Void)?
    ) {
        self.openSettingsAction = openSettings
        self.retryAction = retry
        self.replaceAPIKeyAction = replaceAPIKey
        self.testWSRoundtripAction = testWSRoundtrip
        self.checkForUpdatesAction = checkForUpdates
        self.clearContextAction = clearContext
        self.clearLastAppshotAction = clearLastAppshot
        self.setStateAction = setState
    }

    func attachClearLastAppshotItem(into menu: NSMenu) {
        guard clearLastAppshotAction != nil else { return }
        let item = NSMenuItem(
            title: "Clear Last Appshot",
            action: #selector(clearLastAppshot(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func clearLastAppshot(_ sender: NSMenuItem) {
        clearLastAppshotAction?()
    }

    func attachClearContextItem(into menu: NSMenu) {
        guard clearContextAction != nil else { return }
        let item = NSMenuItem(
            title: "Clear Context",
            action: #selector(clearContext(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func clearContext(_ sender: NSMenuItem) {
        clearContextAction?()
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

    func attachCheckForUpdatesItem(into menu: NSMenu) {
        guard checkForUpdatesAction != nil else { return }
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func checkForUpdates(_ sender: NSMenuItem) {
        checkForUpdatesAction?()
    }

#if DEBUG
    var debugSampleContextAction: MenuBarHost.MenuAction?

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

    func attachDebugSampleContextItem(into menu: NSMenu) {
        guard debugSampleContextAction != nil else { return }
        let item = NSMenuItem(
            title: "Debug: Attach Sample Context",
            action: #selector(attachSampleContext(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
    }

    @objc func attachSampleContext(_ sender: NSMenuItem) {
        debugSampleContextAction?()
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
