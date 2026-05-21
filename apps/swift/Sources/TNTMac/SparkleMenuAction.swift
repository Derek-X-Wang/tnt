// Thin SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`.
//
// Sparkle's controller is an AppKit `NSObject`. This wrapper:
//   1. Owns the controller's lifecycle (init at app startup).
//   2. Exposes a single `checkForUpdates()` method the menu calls.
//   3. Keeps Sparkle's types out of `MenuBarHost` (TNTPlatformMac), which
//      is otherwise free of update-system coupling.
//
// Mirrors the ctxfs pattern (swift/ContextFS/ContextFS/SparkleMenuAction.swift).

import Foundation
import Sparkle

@MainActor
final class SparkleMenuAction {
    private let updaterController: SPUStandardUpdaterController

    init() {
        // startingUpdater: true  → begin background version checks immediately.
        //                          Frequency comes from Info.plist
        //                          SUScheduledCheckInterval (project.yml
        //                          sets 86400 = once per day).
        // updaterDelegate: nil   → accept Sparkle's default behavior.
        // userDriverDelegate: nil → accept Sparkle's default UI.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Trigger a user-visible update check. Called from the menu bar item.
    /// Shows Sparkle's dialog whether or not an update is available — this
    /// matches the "Check for Updates…" affordance in every Mac app that
    /// ships Sparkle.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
