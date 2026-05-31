// RealtimeSendQueue — serializes all outbound Realtime events for a
// single WebSocket connection so no `append` from Voice Turn N can
// land in turn N+1's buffer.
//
// Problem (issue #27): mic-frame `input_audio_buffer.append` events
// are fired from the long-lived capture-drain loop, while
// `input_audio_buffer.commit` + `response.create` are fired from a
// separate Task. Both run through this actor but interleave at `await`
// points — a frame already issued via `sendAppend` but suspended at
// `await transport.sendText` can be re-entered by a concurrent
// `drain()` call, causing `drain()` to return before the transport
// write completes. The prior fix used `assert`, which compiles out in
// release and therefore provided no real barrier.
//
// Fix (issue #66): `drain()` is now a true barrier. When
// `pendingAppendCount > 0` it parks on a `CheckedContinuation`
// stored in `drainWaiters`. Every time `pendingAppendCount` reaches
// zero, all parked continuations are resumed. This ensures commit +
// response.create cannot be sent until every preceding
// `transport.sendText` for the current turn has completed.

import Foundation

/// Serialized send queue for all outbound Realtime events.
///
/// Usage pattern in `VoiceTurnController`:
/// 1. Every `input_audio_buffer.append` calls `sendAppend(_:)`.
/// 2. On hotkey release, call `drain()` before sending commit +
///    `response.create` — `drain()` suspends until every in-flight
///    append has been written to the transport.
public actor RealtimeSendQueue {

    private let transport: RealtimeTransport

    /// Count of `sendAppend` calls currently awaiting their
    /// `transport.sendText`. Incremented synchronously before the
    /// transport await, decremented in `defer` after.
    private var pendingAppendCount: Int = 0

    /// Continuations parked inside `drain()` waiting for
    /// `pendingAppendCount` to reach zero. Resumed by
    /// `notifyDrainWaitersIfIdle()`.
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Ordered log of all outbound event type strings. Used by tests
    /// to assert send ordering without inspecting raw JSON.
    private(set) public var sendLog: [String] = []

    /// Reused JSON encoder. The actor serializes all access, so a single
    /// encoder is safe and avoids re-allocating one per outbound event —
    /// `sendRaw` is on the per-mic-frame append path (~12 events/sec while
    /// the hotkey is held).
    private let encoder = JSONEncoder()

    public init(transport: RealtimeTransport) {
        self.transport = transport
    }

    // MARK: - Append (mic frames)

    /// Encode and send an `input_audio_buffer.append` event.
    ///
    /// Increments `pendingAppendCount` synchronously (before the
    /// transport await) and decrements it in a `defer` after, so
    /// `drain()` can accurately track in-flight appends and park
    /// until they all complete.
    public func sendAppend<E: Encodable>(_ event: E) async throws {
        pendingAppendCount += 1
        defer {
            pendingAppendCount -= 1
            notifyDrainWaitersIfIdle()
        }
        try await sendRaw(event, typeHint: "input_audio_buffer.append")
    }

    // MARK: - Drain barrier

    /// Suspend until all in-flight appends have been written to the
    /// transport. After `drain()` returns, it is safe to send
    /// `input_audio_buffer.commit` + `response.create` — they are
    /// guaranteed to arrive after every append for the current turn.
    ///
    /// If `pendingAppendCount` is already zero the method returns
    /// immediately without suspending. Otherwise it parks on a
    /// `CheckedContinuation` that is resumed by the last in-flight
    /// `sendAppend` when it decrements the counter to zero.
    ///
    /// This is the fix for the ordering hole identified in issue #66:
    /// the previous `assert`-only implementation returned immediately
    /// regardless of in-flight state (assert compiles out in release)
    /// and relied on the incorrect assumption that actor re-entrancy
    /// across `await` points is FIFO.
    public func drain() async {
        guard pendingAppendCount > 0 else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainWaiters.append(cont)
        }
    }

    // MARK: - Non-append events (commit, create, cancel, clear)

    /// Send any non-append outbound event (commit, response.create,
    /// response.cancel, input_audio_buffer.clear). Does NOT affect
    /// `pendingAppendCount`; callers should call `drain()` first when
    /// ordering relative to preceding appends matters.
    public func send<E: Encodable>(_ event: E) async throws {
        try await sendRaw(event, typeHint: nil)
    }

    // MARK: - Private

    /// Wake all parked `drain()` waiters when `pendingAppendCount`
    /// reaches zero. Called from the `defer` block inside `sendAppend`.
    ///
    /// Must be called on the actor (already satisfied because `defer`
    /// in `sendAppend` runs on the actor after the transport await
    /// resumes).
    private func notifyDrainWaitersIfIdle() {
        guard pendingAppendCount == 0, !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters = []
        for cont in waiters {
            cont.resume()
        }
    }

    private func sendRaw<E: Encodable>(_ event: E, typeHint: String?) async throws {
        let data = try encoder.encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeSendQueueError.encodingFailed
        }
        // Record the event type in the send log for test assertions.
        if let hint = typeHint {
            sendLog.append(hint)
        } else if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = parsed["type"] as? String {
            sendLog.append(type_)
        }
        try await transport.sendText(text)
    }
}

public enum RealtimeSendQueueError: Error, Equatable, Sendable {
    case encodingFailed
}
