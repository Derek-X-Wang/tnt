// AudioLevel — peak-dB measurement for PCM16 frame data.
//
// Used by the menu-bar VU indicator to show the User that the mic is
// actually picking up their voice (per the M0/S6 acceptance demo: the
// indicator should peak much higher on speech than on background music
// thanks to `VoiceProcessingIO`'s built-in echo cancellation).

import Foundation

public enum AudioLevel {

    /// Floor we clamp silence to — `log10(0)` would be `-inf`, which
    /// breaks downstream colour math. -60 dB is "quiet room" on most
    /// consumer mics.
    public static let floorDB: Float = -60.0

    /// Peak dB (relative to full scale) of a little-endian PCM16 frame.
    public static func peakDB(from data: Data) -> Float {
        guard !data.isEmpty else { return floorDB }

        var maxAbs: Int32 = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for sample in samples {
                let value = Int32(Int16(littleEndian: sample))
                let magnitude = abs(value)
                if magnitude > maxAbs { maxAbs = magnitude }
            }
        }

        guard maxAbs > 0 else { return floorDB }

        let normalized = Float(maxAbs) / Float(Int16.max)
        let db = 20 * log10f(max(normalized, .leastNormalMagnitude))
        return max(db, floorDB)
    }
}
