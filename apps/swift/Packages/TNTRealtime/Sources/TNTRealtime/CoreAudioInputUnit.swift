// CoreAudioInputUnit — raw AUHAL mic capture (issue #141), the VoiceInk pattern.
//
// Replaces AVAudioEngine.installTap for capture. macOS-only (HALOutput is a
// macOS audio unit). Playback stays on AVAudioEngine in RealtimeAudioSession.
//
// Why AUHAL (research #136): AVAudioEngine pause/resume across long idle silently
// zombies the input tap (start succeeds, isRunning true, 0 frames) and
// inputNode.outputFormat(forBus:) blocks ~5s on a stale device. A HALOutput unit
// read synchronously + kept initialized-but-stopped avoids both: warm device,
// instant start, mic indicator off between turns.
//
// Lifecycle (driven by CaptureControlCore via RealtimeAudioSession):
//   prepare() — create + configure + AudioUnitInitialize (idempotent; warm).
//   start()   — AudioOutputUnitStart.
//   stop()    — AudioOutputUnitStop + AudioUnitReset (NOT uninitialize → warm).
//   teardown()— stop + remove listener + AudioUnitUninitialize + dispose.
//
// Realtime hygiene (counsel): the render callback only does AudioUnitRender into
// a pre-allocated AudioBufferList and a non-blocking ring write of channel 0.
// No allocation, no Swift collection, no lock-that-blocks, no conversion — all of
// that happens off the render thread (NativeCapturePipeline drains the ring).

#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import os

private let auhalLog = Logger(subsystem: "com.derekxwang.tnt", category: "audio")

/// The C render callback. Cannot capture Swift context, so `self` is passed
/// through `inputProcRefCon` and reconstructed here. Runs on the realtime thread.
private let captureRenderCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let unit = Unmanaged<CoreAudioInputUnit>.fromOpaque(refCon).takeUnretainedValue()
    return unit.render(ioActionFlags: ioActionFlags, timeStamp: inTimeStamp, frames: inNumberFrames)
}

final class CoreAudioInputUnit: @unchecked Sendable {

    enum CaptureError: Error {
        case componentNotFound
        case osStatus(String, OSStatus)
    }

    // MARK: - Injected

    private let ring: CaptureFloatRing
    /// Called (off the realtime thread) when the default input device changes,
    /// so the owner can bump the control core's generation and rebuild.
    private let onDeviceChanged: @Sendable () -> Void

    // MARK: - Unit + state

    private var unit: AudioUnit?
    private(set) var isInitialized = false
    private(set) var isRunning = false
    private(set) var deviceID: AudioDeviceID = 0

    /// Native format read from the device at prepare() — the pipeline needs this.
    private(set) var nativeSampleRate: Double = 48_000
    private(set) var nativeChannelCount: Int = 1

    // MARK: - Pre-allocated render scratch

    private let maxFrames = 4096
    private var bufferList: UnsafeMutableAudioBufferListPointer?

    // MARK: - Device listener

    private let listenerQueue = DispatchQueue(label: "com.derekxwang.tnt.capture.devicelistener")
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(ring: CaptureFloatRing, onDeviceChanged: @escaping @Sendable () -> Void) {
        self.ring = ring
        self.onDeviceChanged = onDeviceChanged
    }

    deinit { teardown() }

    /// The current native format as the pure-core value type.
    var nativeFormat: NativeCaptureFormat {
        NativeCaptureFormat(
            sampleRate: nativeSampleRate,
            channelCount: nativeChannelCount,
            encoding: .float32,
            layout: .nonInterleaved
        )
    }

    // MARK: - Lifecycle

    /// Create + configure + initialize the unit for the current default input
    /// device. Idempotent: a no-op if already initialized for that device.
    func prepare() throws {
        let currentDefault = Self.defaultInputDevice()
        if isInitialized, currentDefault == deviceID { return }   // warm, same device
        if isInitialized { teardown() }                            // device changed → rebuild

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CaptureError.componentNotFound }
        var au: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(comp, &au))
        guard let au else { throw CaptureError.componentNotFound }
        self.unit = au

        // Enable input (element 1), disable output (element 0).
        var enable: UInt32 = 1
        try check("EnableIO input", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size)))
        var disable: UInt32 = 0
        try check("EnableIO output off", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disable, UInt32(MemoryLayout<UInt32>.size)))

        // Bind to the default input device explicitly (does NOT change the
        // system default — we only set this unit's device).
        var dev = currentDefault
        try check("CurrentDevice", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))
        self.deviceID = currentDefault

        // Read the device's native input format SYNCHRONOUSLY (no 5s block).
        var nativeASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("get native StreamFormat", AudioUnitGetProperty(
            au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
            &nativeASBD, &asbdSize))
        self.nativeSampleRate = nativeASBD.mSampleRate > 0 ? nativeASBD.mSampleRate : 48_000
        self.nativeChannelCount = max(1, Int(nativeASBD.mChannelsPerFrame))

        // Set our client format: Float32, non-interleaved, native rate + channels.
        // We extract channel 0 in the render callback (the pipeline's channel-0
        // contract), so we keep all native channels here and pick plane 0.
        var client = Self.float32NonInterleaved(
            sampleRate: nativeSampleRate, channels: UInt32(nativeChannelCount))
        try check("set client StreamFormat", AudioUnitSetProperty(
            au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        allocateBufferList(channels: nativeChannelCount)

        // Install the render (input) callback.
        var cb = AURenderCallbackStruct(
            inputProc: captureRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("SetInputCallback", AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        try check("AudioUnitInitialize", AudioUnitInitialize(au))
        isInitialized = true
        addDeviceListener()
        auhalLog.info("CoreAudioInputUnit: prepared dev=\(currentDefault, privacy: .public) \(self.nativeSampleRate, privacy: .public)Hz ch=\(self.nativeChannelCount, privacy: .public)")
    }

    func start() throws {
        guard let unit, isInitialized, !isRunning else { return }
        try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
        isRunning = true
    }

    /// Stop capture but keep the unit initialized (warm) so the next start is
    /// instant and the mic indicator clears.
    func stop() {
        guard let unit, isRunning else { return }
        AudioOutputUnitStop(unit)
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
        isRunning = false
    }

    /// Full teardown: stop, remove listener, uninitialize, dispose, free buffers.
    func teardown() {
        removeDeviceListener()
        if let unit {
            if isRunning { AudioOutputUnitStop(unit); isRunning = false }
            if isInitialized { AudioUnitUninitialize(unit) }
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isInitialized = false
        freeBufferList()
    }

    // MARK: - Render (realtime thread)

    fileprivate func render(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let abl = bufferList else { return noErr }
        let n = min(Int(frames), maxFrames)
        let byteSize = UInt32(n * MemoryLayout<Float>.size)
        for i in 0..<abl.count { abl[i].mDataByteSize = byteSize }

        let status = AudioUnitRender(unit, ioActionFlags, timeStamp, 1, frames, abl.unsafeMutablePointer)
        if status != noErr { return status }

        // Channel 0 → ring (non-blocking). Conversion happens off-thread.
        if let ch0 = abl[0].mData {
            ring.write(ch0.assumingMemoryBound(to: Float.self), count: n)
        }
        return noErr
    }

    // MARK: - Helpers

    static func defaultInputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private static func float32NonInterleaved(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,   // non-interleaved: one channel's frame = 4 bytes
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    private func allocateBufferList(channels: Int) {
        freeBufferList()
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            let data = UnsafeMutableRawPointer.allocate(
                byteCount: maxFrames * MemoryLayout<Float>.size,
                alignment: MemoryLayout<Float>.alignment)
            abl[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.size),
                mData: data)
        }
        bufferList = abl
    }

    private func freeBufferList() {
        guard let abl = bufferList else { return }
        for i in 0..<abl.count { abl[i].mData?.deallocate() }
        free(abl.unsafeMutablePointer)
        bufferList = nil
    }

    private func addDeviceListener() {
        guard deviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDeviceChanged()
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress, listenerQueue, block)
    }

    private func removeDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress, listenerQueue, block)
        deviceListenerBlock = nil
    }

    private func check(_ what: String, _ status: OSStatus) throws {
        guard status == noErr else {
            auhalLog.error("CoreAudioInputUnit: \(what, privacy: .public) failed: \(status, privacy: .public)")
            throw CaptureError.osStatus(what, status)
        }
    }
}
#endif
