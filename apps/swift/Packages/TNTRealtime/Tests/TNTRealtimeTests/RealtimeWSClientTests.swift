import XCTest
@testable import TNTRealtime

/// `OpenAIRealtimeWSClient` integration tests over a `MockTransport`.
final class RealtimeWSClientTests: XCTestCase {

    func testUpgradeRequestCarriesAuthBetaAndZDRHeaders() {
        let client = OpenAIRealtimeWSClient(
            apiKey: "sk-test",
            transport: MockTransport()
        )
        let request = client.makeRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "realtime=v1")
        XCTAssertEqual(request.value(forHTTPHeaderField: OpenAIRealtimeWSClient.zdrHeader), "true",
                       "ZDR request header per ADR-0004 must be set on every upgrade.")
        XCTAssertTrue(request.url?.absoluteString.contains("model=gpt-realtime-2") ?? false,
                      "Default model goes onto the URL as the `model` query parameter.")
    }

    func testForwardsInboundEventsToInboundStream() async throws {
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport)
        try await client.connect()

        transport.enqueueText(#"{"type":"session.created"}"#)
        transport.enqueueText(#"{"type":"response.audio.delta","response_id":"r","item_id":"i","delta":"AAA="}"#)

        var iterator = client.inbound.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        guard case .sessionCreated = first else {
            XCTFail("Expected sessionCreated, got \(String(describing: first))")
            return
        }
        guard case .responseAudioDelta(let delta) = second else {
            XCTFail("Expected responseAudioDelta, got \(String(describing: second))")
            return
        }
        XCTAssertEqual(delta.delta, "AAA=")

        await client.disconnect()
    }

    func testReconnectsOnTransportFailure() async throws {
        // Mock plays one frame, then errors. The client must reconnect
        // once and continue draining further frames pushed onto the
        // mock after the reconnect.
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport, maxReconnectAttempts: 1)
        try await client.connect()
        XCTAssertEqual(transport.connectCount, 1)

        transport.enqueueText(#"{"type":"session.created"}"#)
        // Trigger a transport error AFTER the first frame has been
        // queued so the receive loop sees one good frame, then fails,
        // then reconnects.
        try? await Task.sleep(nanoseconds: 50_000_000)
        transport.enqueueError(RealtimeTransportError.streamClosed)

        // Wait for reconnect to settle. With one retry permitted, the
        // mock should have been connected exactly twice.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && transport.connectCount < 2 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(transport.connectCount, 2, "WSClient must reconnect once on transport failure.")

        await client.disconnect()
    }

    func testSurfacesFatalErrorWhenReconnectExhausts() async throws {
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport, maxReconnectAttempts: 0)
        try await client.connect()

        transport.enqueueError(RealtimeTransportError.streamClosed)

        var iterator = client.inbound.makeAsyncIterator()
        let event = await iterator.next()
        guard case .error(let err) = event else {
            XCTFail("Expected fatal .error event, got \(String(describing: event))")
            return
        }
        XCTAssertEqual(err.error.code, "stream_closed")

        await client.disconnect()
    }

    func testSecondConnectThrowsAlreadyConnected() async throws {
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport)
        try await client.connect()
        do {
            try await client.connect()
            XCTFail("Expected alreadyConnected error.")
        } catch RealtimeWSError.alreadyConnected {
            // ok
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        await client.disconnect()
    }

    func testSendSerializesEncodableEventToTextFrame() async throws {
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport)
        try await client.connect()

        try await client.send(InputAudioBufferAppend(audio: "AAA="))
        XCTAssertEqual(transport.sendLog.count, 1)
        let json = try JSONSerialization.jsonObject(with: Data(transport.sendLog[0].utf8)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json?["audio"] as? String, "AAA=")

        await client.disconnect()
    }
}
