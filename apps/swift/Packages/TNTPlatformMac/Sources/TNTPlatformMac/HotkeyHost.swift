// HotkeyHost — owns the `CGEventTap` that listens for the configured
// `HotkeyChord` system-wide and drives a `HotkeyGestureRecognizer`.
//
// Permanent-client per ADR-0003: the event tap is a macOS-only OS
// resource, so this stays a `final class` with no protocol layer.
//
// Threading: `CGEventTap` callbacks fire on whatever thread the run-
// loop source belongs to. We extract primitive event data inside the
// C callback (which only sees `Sendable` values), then hop to the main
// actor before mutating recognizer state and notifying the listener.
//
// Permissions: `CGEvent.tapCreate` returns `nil` when the app lacks
// Input Monitoring TCC permission. We surface that as
// `Authorization.denied` and expose a `recheckAuthorization()` method
// for the menu's "Retry" affordance.

import AppKit

@MainActor
public final class HotkeyHost {

    public enum Authorization: Sendable, Equatable {
        case unknown
        case granted
        case denied
    }

    /// Side-effects produced by the recognizer that the host forwards
    /// to the `MenuBarHost`. `Authorization` flips through `permissionChanged`.
    public enum Event: Sendable, Equatable {
        case startListening
        case stopListening
        /// Single press of the Appshot Hotkey (M4a, #34) — capture + arm.
        case captureAppshot
        case permissionChanged(Authorization)
    }

    public typealias Listener = @MainActor (Event) -> Void

    public private(set) var authorization: Authorization = .unknown
    public private(set) var chord: HotkeyChord

    /// Optional second chord (M4a, #34): the Appshot Hotkey (default
    /// ⌃⌥⇧Space). Press-only — one keyDown, one capture; no hold/tap.
    /// Shares the single CGEventTap with the voice chord; chord matching
    /// is exact-modifier, so the shift superset never triggers the voice
    /// chord and vice versa.
    public private(set) var appshotChord: HotkeyChord?

    private var recognizer: HotkeyGestureRecognizer
    private var appshotRecognizer = AppShotHotkeyGestureRecognizer()
    private let listener: Listener
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var box: HotkeyHostBox?

    /// Triggers the Input Monitoring first-run prompt (side-effect only — we
    /// never gate on its result). Injectable for tests; default = the real CG
    /// call.
    private let requestListenAccess: () -> Bool
    /// Installs the `CGEventTap`, returning true on success. `nil` → the real
    /// installer. Injectable so tests can exercise the #138 stale-TCC retry
    /// ladder without a live event tap / run loop.
    private let installTapOverride: (() -> Bool)?
    /// Schedules a delayed retry. Default = main-queue `asyncAfter`; tests
    /// inject a synchronous runner.
    private let retryScheduler: (TimeInterval, @escaping () -> Void) -> Void

    /// Bounded re-probe delays for `tapCreate` after a denied-looking first
    /// attempt (#138). The Screen-Recording-grant relaunch can leave the
    /// per-process TCC cache frozen-false *before* tccd commits, so we re-probe
    /// `tapCreate` (which reads LIVE TCC) a few times before reporting denied.
    private static let tapRetryDelays: [TimeInterval] = [0.5, 1.5]

    public init(
        chord: HotkeyChord,
        appshotChord: HotkeyChord? = nil,
        configuration: HotkeyGestureRecognizer.Configuration = .init(),
        requestListenAccess: @escaping () -> Bool = { CGRequestListenEventAccess() },
        installTap: (() -> Bool)? = nil,
        retryScheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        listener: @escaping Listener
    ) {
        self.chord = chord
        self.appshotChord = appshotChord
        self.recognizer = HotkeyGestureRecognizer(configuration: configuration)
        self.requestListenAccess = requestListenAccess
        self.installTapOverride = installTap
        self.retryScheduler = retryScheduler
        self.listener = listener
    }

    deinit {
        // Best-effort: tap teardown must run on the MainActor; if the
        // host is released off-thread, the OS cleans up when the run
        // loop drains.
    }

    /// Start listening. Triggers the Input Monitoring permission prompt
    /// the first time the user holds the chord; reports the resulting
    /// authorization through `Event.permissionChanged`.
    public func start() {
        guard eventTap == nil else {
            TNTLog.hotkey.info("start: tap already installed, no-op")
            return
        }

        // `CGRequestListenEventAccess()` triggers the system prompt the first
        // time it's called for a given app, then short-circuits to a cached
        // answer. We call it ONLY for that prompt side-effect — we do NOT gate
        // on its result. After the Screen-Recording-grant relaunch (#138) it
        // returns a STALE false: the per-process TCC cache froze before tccd
        // committed, even though Input Monitoring is granted in the live TCC
        // db. `CGEvent.tapCreate` reads LIVE TCC per call (it is not subject to
        // that frozen cache), so the tap itself — not this cached bool — is the
        // source of truth for authorization. (Apple DTS / forums 735204.)
        let preflight = CGPreflightListenEventAccess()
        let requested = requestListenAccess()
        TNTLog.hotkey.info("start: chord=\(self.chord.displayString, privacy: .public) preflight=\(preflight) requestAccess=\(requested)")

        attemptInstall(remainingDelays: Self.tapRetryDelays, requested: requested)
    }

    /// Try to install the tap; on failure re-probe `tapCreate` after a bounded
    /// set of delays before reporting `.denied`. The first attempt is
    /// immediate; the retries cover the residual window where the live TCC
    /// grant is not yet visible *anywhere* right after the SR-grant relaunch
    /// (#138) — re-probing `tapCreate`, never the frozen `requestAccess`.
    private func attemptInstall(remainingDelays: [TimeInterval], requested: Bool) {
        guard eventTap == nil else { return }  // a concurrent success / Retry won

        if installTap() {
            TNTLog.hotkey.info("start: event tap installed + enabled, authorization granted (requestAccess=\(requested))")
            updateAuthorization(.granted)
            return
        }

        guard let nextDelay = remainingDelays.first else {
            TNTLog.hotkey.error("start: tapCreate returned nil after retries — Input Monitoring not granted. Grant in System Settings › Privacy & Security › Input Monitoring, then Retry or Quit & Reopen.")
            updateAuthorization(.denied)
            return
        }

        let rest = Array(remainingDelays.dropFirst())
        TNTLog.hotkey.info("start: tapCreate nil — re-probing live TCC in \(nextDelay)s (stale cache after Screen Recording grant?)")
        retryScheduler(nextDelay) { [weak self] in
            self?.attemptInstall(remainingDelays: rest, requested: requested)
        }
    }

    /// Real-or-injected tap installer. The override lets tests drive the
    /// authorization/retry logic without a live `CGEventTap` + run loop.
    private func installTap() -> Bool {
        installTapOverride?() ?? installEventTap()
    }

    /// Tear down the event tap. Idempotent.
    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        box = nil
    }

    /// Re-attempt installing the tap. The "Retry" menu item calls this
    /// after the user grants Input Monitoring in System Settings. Works
    /// in-process now (#138): `start()` probes the live-TCC `tapCreate`
    /// rather than the frozen `CGRequestListenEventAccess` cache.
    public func recheckAuthorization() {
        stop()
        start()
    }

    /// Re-enable the tap after macOS disables it (Secure Input focus, system
    /// sleep/wake, or a slow callback). A non-nil tap that has been disabled
    /// delivers no events until re-enabled — "a non-nil tap is not a healthy
    /// tap." Called from the tap callback on `kCGEventTapDisabledBy*`.
    fileprivate func reEnableTap() {
        guard let tap = eventTap else { return }
        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        TNTLog.hotkey.info("re-enabled event tap after system disable (Secure Input / sleep-wake)")
    }

    // MARK: - Tap installation

    private func installEventTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let box = HotkeyHostBox(host: self)
        self.box = box

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            self.box = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    // MARK: - Event handling (called on MainActor)

    fileprivate func handleEvent(type: CGEventType, timestamp: TimeInterval, flags: CGEventFlags, keyCode: UInt16) {
        // Appshot chord first: it is the more-specific chord (shift superset
        // of the voice chord). Exact-modifier matching means a matched
        // appshot keyDown can never also be a voice keyDown — consume it.
        if let appshotChord {
            if type == .keyDown, appshotChord.matchesKeyDown(flags: flags, keyCode: keyCode) {
                let effect = appshotRecognizer.keyDown()
                TNTLog.hotkey.info("appshot keyDown effect=\(String(describing: effect), privacy: .public)")
                if effect == .captureAppshot {
                    listener(.captureAppshot)
                }
                return
            }
            if type == .keyUp, appshotChord.matchesKeyUp(keyCode: keyCode) {
                // Reset the press-only recognizer; the voice recognizer also
                // sees this keyUp below (shared Space key) and safely no-ops
                // unless its own gesture is open.
                _ = appshotRecognizer.keyUp()
            }
        }
        // Match policy lives on `HotkeyChord` (pure + unit-tested): a
        // keyDown needs the full chord to *open* a gesture; a keyUp needs
        // only the key to *close* one, because the modifier is often
        // already released by the time the key's keyUp lands.
        // Compute the match decision once. Only the chord's own key is
        // ever logged — never arbitrary keystrokes (this is a system-wide
        // tap; logging every key would be keylogging).
        let isChordKey = keyCode == chord.key.cgKeyCode
        let matchDown = chord.matchesKeyDown(flags: flags, keyCode: keyCode)
        let matchUp = chord.matchesKeyUp(keyCode: keyCode)
        if isChordKey {
            let kind = type == .keyDown ? "keyDown" : "keyUp"
            TNTLog.hotkey.info("event \(kind, privacy: .public) keyCode=\(keyCode, privacy: .public) flags=\(flags.rawValue, privacy: .public) matchDown=\(matchDown, privacy: .public) matchUp=\(matchUp, privacy: .public)")
        }

        let effect: HotkeyGestureRecognizer.Effect
        switch type {
        case .keyDown:
            guard matchDown else { return }
            effect = recognizer.keyDown(at: timestamp)
        case .keyUp:
            guard matchUp else { return }
            effect = recognizer.keyUp(at: timestamp)
        default:
            return
        }
        if isChordKey {
            TNTLog.hotkey.info("effect=\(String(describing: effect), privacy: .public)")
        }
        switch effect {
        case .startListening: listener(.startListening)
        case .stopListening:  listener(.stopListening)
        case .noChange:       break
        }
    }

    private func updateAuthorization(_ new: Authorization) {
        guard authorization != new else { return }
        authorization = new
        listener(.permissionChanged(new))
    }
}

// MARK: - Run-loop bridge

/// `CGEventTapCallBack` only carries a raw user-info pointer. This box
/// keeps a weak reference to the host so a torn-down tap never resolves
/// to a freed instance during in-flight callbacks.
private final class HotkeyHostBox {
    weak var host: HotkeyHost?
    init(host: HotkeyHost) { self.host = host }
}

/// Fires on whatever thread `cgSessionEventTap` runs on. We extract
/// primitive `Sendable` values here, then dispatch onto the main actor
/// where the recognizer state lives.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let box = Unmanaged<HotkeyHostBox>.fromOpaque(userInfo).takeUnretainedValue()

    // macOS disables the tap on Secure Input focus, sleep/wake, or a slow
    // callback; these arrive as out-of-band event types (not key events).
    // Re-enable on the main actor so the hotkey survives without a relaunch.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.host?.reEnableTap() }
        }
        return Unmanaged.passUnretained(event)
    }

    let now = CFAbsoluteTimeGetCurrent()
    let flags = event.flags
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            box.host?.handleEvent(type: type, timestamp: now, flags: flags, keyCode: keyCode)
        }
    }

    return Unmanaged.passUnretained(event)
}
