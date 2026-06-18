// NativeCaptureFormat — plain description of the audio format produced by a
// native capture unit (AUHAL, AVAudioEngine tap, etc.).
//
// Design rule: NO AudioToolbox / CoreAudio types appear anywhere in this file.
// The HITL adapter translates its AudioStreamBasicDescription (or AVAudioFormat)
// into this value before crossing into the pure-core boundary.  That keeps the
// PCM pipeline and its tests entirely free of framework imports.

import Foundation

/// Describes the PCM sample stream produced by a native audio capture unit.
/// All fields are plain Swift scalars; no AudioToolbox types are used.
public struct NativeCaptureFormat: Sendable, Equatable {

    /// Sample encoding of each individual sample value.
    public enum SampleEncoding: Sendable, Equatable {
        /// 32-bit IEEE float, range nominally –1.0 … +1.0.
        case float32
        /// 16-bit signed integer (little-endian).
        case int16
    }

    /// Memory organisation of channels within a single buffer set.
    public enum ChannelLayout: Sendable, Equatable {
        /// All channels packed sample-by-sample in one contiguous buffer
        /// (e.g. LRLRLR…).
        case interleaved
        /// Each channel in its own separate buffer / plane (AUHAL default).
        case nonInterleaved
    }

    /// Hardware sample rate in Hz.
    public let sampleRate: Double
    /// Number of channels the capture unit delivers.
    public let channelCount: Int
    /// Per-sample encoding.
    public let encoding: SampleEncoding
    /// Channel memory layout.
    public let layout: ChannelLayout

    public init(
        sampleRate: Double,
        channelCount: Int,
        encoding: SampleEncoding,
        layout: ChannelLayout
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.encoding = encoding
        self.layout = layout
    }

    // MARK: - Common presets

    /// Typical AUHAL output on Apple Silicon Macs: Float32, non-interleaved,
    /// mono, 48 kHz.
    public static let auhalMono48k = NativeCaptureFormat(
        sampleRate: 48_000, channelCount: 1,
        encoding: .float32, layout: .nonInterleaved
    )

    /// 5-channel aggregate device (e.g., Mac Studio / Mac Pro built-in).
    /// The PCM pipeline selects channel 0 explicitly so the caller never
    /// needs to perform a channel-map step.
    public static func auhalFiveChannel(sampleRate: Double = 48_000) -> NativeCaptureFormat {
        NativeCaptureFormat(
            sampleRate: sampleRate, channelCount: 5,
            encoding: .float32, layout: .nonInterleaved
        )
    }
}
