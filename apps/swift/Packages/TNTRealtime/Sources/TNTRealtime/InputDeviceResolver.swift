// InputDeviceResolver — pure policy for choosing TNT's capture device (#154).
//
// TNT is duplex (mic + speaker). Opening a classic Bluetooth headset (AirPods)
// as the INPUT forces macOS into HFP "call mode" (24 kHz) and thrashes the BT
// route HFP↔A2DP every turn → dropped/garbled replies. The fix: do NOT open a
// classic-Bluetooth device as input unless the user explicitly opts in — pick
// the built-in mic instead, leaving AirPods as high-quality A2DP output.
//
// This file is PURE (Foundation only, no CoreAudio): the CoreAudio enumeration
// + transport-type reads live in CoreAudioInputUnit (macOS) and feed plain
// values into `resolveInputDevice`. Trigger is TRANSPORT TYPE, not sample rate
// (by the time you observe 24 kHz the HFP switch already happened).

import Foundation

/// Coarse transport classification of an audio device.
public enum AudioTransport: Equatable, Sendable {
    /// Classic Bluetooth (A2DP/HFP) — the one we avoid opening as input.
    case bluetooth
    /// Bluetooth LE Audio — NOT avoided (may not force HFP); logged separately.
    case bluetoothLE
    case builtIn
    /// USB, wired, aggregate, virtual, anything else — all acceptable as input.
    case other
}

/// A candidate input device, reduced to the fields the policy needs.
public struct ResolvableInput: Equatable, Sendable {
    public let id: UInt32          // AudioDeviceID
    public let transport: AudioTransport
    public let hasInputStreams: Bool
    public init(id: UInt32, transport: AudioTransport, hasInputStreams: Bool) {
        self.id = id
        self.transport = transport
        self.hasInputStreams = hasInputStreams
    }
}

/// Resolve which device TNT should capture from.
///
/// Fallback ladder (counsel-validated, #154):
/// 1. Escape toggle on → system default exactly (honor explicit user intent).
/// 2. Default input is non-classic-Bluetooth → use it (built-in, USB, LE, …).
/// 3. Default is classic Bluetooth → prefer an alive built-in input.
/// 4. No built-in → another alive non-classic-Bluetooth input.
/// 5. Nothing safe (lid closed, AirPods only) → the Bluetooth default (caller logs).
///
/// - Returns: the chosen device id, or nil if there is no usable input at all.
public func resolveInputDevice(
    systemDefault: ResolvableInput?,
    all: [ResolvableInput],
    useSystemDefault: Bool
) -> UInt32? {
    guard let def = systemDefault else {
        // No default — fall back to any device that can actually capture.
        return all.first(where: { $0.hasInputStreams })?.id
    }

    // 1. Explicit opt-out: honor the system default exactly.
    if useSystemDefault { return def.id }

    // 2. Default isn't classic Bluetooth → safe to use as-is (LE allowed).
    if def.transport != .bluetooth { return def.id }

    // 3. Classic-BT default → prefer an alive built-in input.
    if let builtIn = all.first(where: { $0.transport == .builtIn && $0.hasInputStreams }) {
        return builtIn.id
    }
    // 4. Else any alive non-classic-Bluetooth input.
    if let nonBT = all.first(where: { $0.transport != .bluetooth && $0.hasInputStreams }) {
        return nonBT.id
    }
    // 5. No safe alternative → the Bluetooth default (caller logs "no safe fallback").
    return def.id
}
