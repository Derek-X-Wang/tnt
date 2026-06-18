// CaptureFloatRing — single-producer / single-consumer Float ring buffer for the
// AUHAL render-thread → off-thread consumer hand-off (issue #141).
//
// The render callback (producer) must never block. It uses a NON-BLOCKING
// `os_unfair_lock_trylock`: if the lock is momentarily held by the consumer it
// drops the chunk and counts it rather than waiting (priority-inversion-safe —
// exactly the "tryLock on the producer side" option the audio research named).
// The consumer (an off-RT task) drains with a normal blocking lock.
//
// Only mono Float32 samples (already channel-0-extracted in the render callback)
// flow through here; conversion/resampling happens downstream in
// NativeCapturePipeline, OFF the render thread.

import Foundation
import os

public final class CaptureFloatRing: @unchecked Sendable {

    private var storage: [Float]
    private let capacity: Int
    private var head = 0          // consumer read index
    private var tail = 0          // producer write index
    private var count = 0         // valid samples in the ring
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    /// Samples dropped due to overflow or producer-side lock contention.
    /// Producer-only writes; read for diagnostics (a torn read is harmless).
    public private(set) var droppedSamples = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
        self.lockPtr = .allocate(capacity: 1)
        self.lockPtr.initialize(to: os_unfair_lock())
    }

    deinit {
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    /// Producer side — call from the realtime render thread. Non-blocking:
    /// drops (and counts) on lock contention or when the ring is full. Never waits.
    public func write(_ ptr: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        guard os_unfair_lock_trylock(lockPtr) else {
            droppedSamples &+= n   // consumer holds the lock — drop rather than block
            return
        }
        let free = capacity - count
        let toWrite = min(n, free)
        if toWrite < n { droppedSamples &+= (n - toWrite) }
        var t = tail
        for i in 0..<toWrite {
            storage[t] = ptr[i]
            t += 1
            if t == capacity { t = 0 }
        }
        tail = t
        count += toWrite
        os_unfair_lock_unlock(lockPtr)
    }

    /// Consumer side — call from an off-RT task. Copies up to `maxCount` samples
    /// into `out`, returns the number copied (0 if empty).
    public func read(into out: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        os_unfair_lock_lock(lockPtr)
        let toRead = min(maxCount, count)
        var h = head
        for i in 0..<toRead {
            out[i] = storage[h]
            h += 1
            if h == capacity { h = 0 }
        }
        head = h
        count -= toRead
        os_unfair_lock_unlock(lockPtr)
        return toRead
    }

    /// Number of samples currently available to read.
    public var available: Int {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        return count
    }

    /// Clear all pending samples and the dropped counter. Call at turn boundaries.
    public func reset() {
        os_unfair_lock_lock(lockPtr)
        head = 0
        tail = 0
        count = 0
        droppedSamples = 0
        os_unfair_lock_unlock(lockPtr)
    }
}
