// DeliverySinks — real OS-backed implementations of PromptDeliverer's sink
// protocols (issue #51). These live in the TNTMac app target because they
// touch AppKit / UserNotifications, which TNTPlatformMac deliberately does not
// import (PromptDeliverer's protocol layer stays AppKit-free for testability,
// issue #83). The app target wires these in at the composition root.
//
// Delivery is WRITE-ONLY for the pasteboard (ADR-0004 bans reading for context);
// `read()` exists only to satisfy the protocol and is never called by
// PromptDeliverer.

import AppKit
import Foundation
import UserNotifications
import TNTPlatformMac

/// Real pasteboard sink backed by `NSPasteboard.general`.
final class NSPasteboardSink: PasteboardSink {
    func write(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func read() -> String? {
        // Never called by PromptDeliverer (ADR-0004). Present only for the protocol.
        NSPasteboard.general.string(forType: .string)
    }
}

/// Real chime sink backed by a built-in macOS system sound.
final class NSSoundChimeSink: ChimeSink {
    func play() {
        // "Glass" is a standard bundled macOS alert sound — a short, distinct
        // delivery confirmation. Falls back silently if unavailable.
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}

/// Real notification sink backed by `UNUserNotificationCenter`. Authorization is
/// requested once at construction (idempotent — macOS only prompts the first time).
final class UNNotificationSink: NotificationSink {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func fire(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "TNT"
        content.body = message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
