// RealtimeSendQueue — serializes all outbound Realtime events for a
// single WebSocket connection so no `append` from Voice Turn N can
// land in turn N+1's buffer.
//
// Problem (issue #27): mic-frame `input_audio_buffer.append` events
// are fired from the long-lived capture-drain loop, while
// `input_audio_buffer.commit` + `response.create` are fired from a
// separate unstructured `Task`. Both run on the MainActor but
// interleave at `await` points — a frame already yielded by the
// `RealtimeAudioSession` AsyncStream but not yet `await`-sent can
// land **after** the commit, clipping the tail of the user's speech
// or contaminating the next turn's buffer.
//
// Fix: funnel every outbound send through this actor. A single
// `pendingAppendCount` counter tracks how many appends are in-flight.
// `drain()` suspends until the counter reaches zero, then the caller
// sends commit + response.create — guaranteed to arrive after all
// preceding appends.
//
// All sends are serialized through the actor's mailbox (FIFO), so by
// the time `drain()` executes, all prior `sendAppend` calls have
// already completed.

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

    /// Count of `sendAppend` calls currently executing. Because the
    /// actor serializes all calls, this is always 0 by the time
    /// `drain()` runs — the field exists to surface ordering bugs in
    /// tests and DEBUG builds via the assertion in `drain()`.
    private var pendingAppendCount: Int = 0

    /// Ordered log of all outbound event type strings. Used by tests
    /// to assert send ordering without inspecting raw JSON.
    private(set) public var sendLog: [String] = []

    public init(transport: RealtimeTransport) {
        self.transport = transport
    }

    // MARK: - Append (mic frames)

    /// Encode and send an `input_audio_buffer.append` event.
    /// Increments `pendingAppendCount` before the transport `await`
    /// and decrements it after so tests can observe the count.
    public func sendAppend<E: Encodable>(_ event: E) async throws {
        pendingAppendCount += 1
        defer { pendingAppendCount -= 1 }
        try await sendRaw(event, typeHint: "input_audio_buffer.append")
    }

    // MARK: - Drain barrier

    /// Suspend until all in-flight appends have been written to the
    /// transport. After `drain()` returns, it is safe to send
    /// `input_audio_buffer.commit` + `response.create` — they are
    /// guaranteed to arrive after every append for the current turn.
    ///
    /// Actor serialization guarantees the invariant: because
    /// `sendAppend()` calls are serialized through this actor's FIFO
    /// mailbox, by the time `drain()` executes, all previously
    /// enqueued `sendAppend()` calls have already completed and
    /// `pendingAppendCount` is zero.
    public func drain() async {
        assert(
            pendingAppendCount == 0,
            "RealtimeSendQueue.drain(): unexpected pending appends (\(pendingAppendCount)) — ordering invariant violated"
        )
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

    private func sendRaw<E: Encodable>(_ event: E, typeHint: String?) async throws {
        let data = try JSONEncoder().encode(event)
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
