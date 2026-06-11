// ScreenImageCapturer — one-shot frontmost-window image capture (M4b, #127).
// Permanent-client final class per ADR-0003 (ScreenCaptureKit is a macOS-only
// OS resource, no protocol layer). JPEG quality 0.8 via ImageIO; in-memory
// only, never written to disk (ADR-0004).
//
// TCC policy (roadmap M4b): Screen Recording is requested JIT on the first
// `analyze_screen` call — NEVER at launch and never from the Appshot Hotkey.
// The arm path only includes an image when access is ALREADY granted
// (preflight, no prompt), so pressing the hotkey can never fire a TCC dialog.
// macOS may require an app relaunch after the first grant before frames
// arrive — until then capture fails soft to text-only with a diagnosable log.

import AppKit
import ImageIO
import ScreenCaptureKit
import TNTCore
import UniformTypeIdentifiers

@MainActor
public final class ScreenImageCapturer {

    public init() {}

    /// Whether Screen Recording is already granted. Never prompts — safe to
    /// call from the Appshot Hotkey path.
    public static func preflightGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording access (system prompt on first call per app).
    /// Returns the CURRENT grant state — a fresh grant may not take effect
    /// until the app relaunches (macOS behavior, documented in the hardware
    /// checklist). Call ONLY from the `analyze_screen` path (JIT), never at
    /// launch (ADR-0004 amendment: permissions attach to user intent).
    @discardableResult
    public static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Capture the frontmost app's largest on-screen window as JPEG (q 0.8).
    ///
    /// Nil when access is not granted, no frontmost window is found, or the
    /// capture fails — always fail-soft so the text tier keeps working.
    public func captureFrontmostWindowJPEG() async -> Data? {
        guard Self.preflightGranted() else {
            TNTLog.app.info("ScreenImageCapturer: Screen Recording not granted — text-only (grant in System Settings → Privacy & Security → Screen Recording; relaunch may be required)")
            return nil
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            // Largest on-screen window owned by the frontmost app — matches
            // the AX layer's "frontmost window" notion closely enough for a
            // single-window one-shot, without private window-ordering APIs.
            let window = content.windows
                .filter { $0.owningApplication?.processID == frontApp.processIdentifier && $0.isOnScreen }
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            guard let window else {
                TNTLog.app.info("ScreenImageCapturer: no on-screen window for frontmost app — text-only")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // 2x for legible text on Retina; SCK clamps to actual content size.
            config.width = Int(window.frame.width) * 2
            config.height = Int(window.frame.height) * 2
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            let data = Self.jpegData(from: image, quality: 0.8)
            TNTLog.app.info("ScreenImageCapturer: captured \(data?.count ?? 0, privacy: .public) bytes for \(frontApp.localizedName ?? "?", privacy: .public)")
            return data
        } catch {
            TNTLog.app.error("ScreenImageCapturer: capture failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
