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
        case permissionChanged(Authorization)
    }

    public typealias Listener = @MainActor (Event) -> Void

    public private(set) var authorization: Authorization = .unknown
    public private(set) var chord: HotkeyChord

    private var recognizer: HotkeyGestureRecognizer
    private let listener: Listener
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var box: HotkeyHostBox?

    public init(
        chord: HotkeyChord,
        configuration: HotkeyGestureRecognizer.Configuration = .init(),
        listener: @escaping Listener
    ) {
        self.chord = chord
        self.recognizer = HotkeyGestureRecognizer(configuration: configuration)
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
        guard eventTap == nil else { return }

        // `CGRequestListenEventAccess()` triggers the system prompt the
        // first time it's called for a given app, then short-circuits to
        // a cached answer. Calling it before `tapCreate` keeps the prompt
        // attached to the user's first press rather than the OS's idle
        // background detection.
        let granted = CGRequestListenEventAccess()
        guard granted else {
            updateAuthorization(.denied)
            return
        }

        guard installEventTap() else {
            updateAuthorization(.denied)
            return
        }
        updateAuthorization(.granted)
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
    /// after the user grants Input Monitoring in System Settings.
    public func recheckAuthorization() {
        stop()
        start()
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
        // Match policy lives on `HotkeyChord` (pure + unit-tested): a
        // keyDown needs the full chord to *open* a gesture; a keyUp needs
        // only the key to *close* one, because the modifier is often
        // already released by the time the key's keyUp lands.
        let effect: HotkeyGestureRecognizer.Effect
        switch type {
        case .keyDown:
            guard chord.matchesKeyDown(flags: flags, keyCode: keyCode) else { return }
            effect = recognizer.keyDown(at: timestamp)
        case .keyUp:
            guard chord.matchesKeyUp(keyCode: keyCode) else { return }
            effect = recognizer.keyUp(at: timestamp)
        default:
            return
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
