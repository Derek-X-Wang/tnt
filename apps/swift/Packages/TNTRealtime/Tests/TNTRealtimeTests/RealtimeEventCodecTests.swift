import XCTest
@testable import TNTRealtime

/// JSON encode/decode round-trip for the OpenAI Realtime event types
/// the v0 voice-turn flow exercises.
///
/// Per the M0/S7 acceptance criterion, these five event shapes ship
/// pinned: `input_audio_buffer.append`, `response.audio.delta`,
/// `response.cancel`, `input_audio_buffer.clear`, and `error`. The
/// fixtures live alongside the tests so a server-side schema drift
/// shows up here, not as a silent runtime no-op.
final class RealtimeEventCodecTests: XCTestCase {

    // MARK: - input_audio_buffer.append (outbound)

    func testInputAudioBufferAppendEncodesToCanonicalShape() throws {
        let event = InputAudioBufferAppend(audio: "AAA=")
        let json = try Self.encode(event)
        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(json["audio"] as? String, "AAA=")
    }

    func testInputAudioBufferAppendDecodesFromFixture() throws {
        let raw = #"{"type":"input_audio_buffer.append","audio":"AAA="}"#
        let event = try JSONDecoder().decode(InputAudioBufferAppend.self, from: Data(raw.utf8))
        XCTAssertEqual(event.audio, "AAA=")
        XCTAssertEqual(event.type, "input_audio_buffer.append")
    }

    // MARK: - input_audio_buffer.clear (outbound)

    func testInputAudioBufferClearEncodesToCanonicalShape() throws {
        let event = InputAudioBufferClear()
        let json = try Self.encode(event)
        XCTAssertEqual(json["type"] as? String, "input_audio_buffer.clear")
    }

    // MARK: - response.cancel (outbound)

    func testResponseCancelEncodesToCanonicalShape() throws {
        let event = ResponseCancel()
        let json = try Self.encode(event)
        XCTAssertEqual(json["type"] as? String, "response.cancel")
    }

    // MARK: - response.audio.delta (inbound)

    func testResponseAudioDeltaDecodesFromFixture() throws {
        let raw = """
        {
          "type": "response.audio.delta",
          "response_id": "resp_1",
          "item_id": "item_1",
          "delta": "AAEC"
        }
        """
        let event = try JSONDecoder().decode(ResponseAudioDelta.self, from: Data(raw.utf8))
        XCTAssertEqual(event.responseId, "resp_1")
        XCTAssertEqual(event.itemId, "item_1")
        XCTAssertEqual(event.delta, "AAEC")
    }

    // MARK: - error (inbound)

    func testErrorEventDecodesFromFixture() throws {
        let raw = """
        {
          "type": "error",
          "error": {
            "type": "invalid_request_error",
            "code": "invalid_api_key",
            "message": "Incorrect API key provided"
          }
        }
        """
        let event = try JSONDecoder().decode(RealtimeErrorEvent.self, from: Data(raw.utf8))
        XCTAssertEqual(event.error.code, "invalid_api_key")
        XCTAssertEqual(event.error.type, "invalid_request_error")
        XCTAssertEqual(event.error.message, "Incorrect API key provided")
    }

    // MARK: - Server event dispatcher

    func testServerEventDispatcherRoutesAudioDelta() throws {
        let raw = #"{"type":"response.audio.delta","response_id":"r","item_id":"i","delta":"AAA="}"#
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .responseAudioDelta(let payload) = event else {
            XCTFail("Expected responseAudioDelta, got \(event)")
            return
        }
        XCTAssertEqual(payload.delta, "AAA=")
    }

    func testServerEventDispatcherRoutesError() throws {
        let raw = #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_api_key","message":"nope"}}"#
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .error(let err) = event else {
            XCTFail("Expected error, got \(event)")
            return
        }
        XCTAssertEqual(err.error.code, "invalid_api_key")
    }

    func testServerEventDispatcherFallsBackToUnknown() throws {
        let raw = #"{"type":"future.event.shape","extra":42}"#
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown, got \(event)")
            return
        }
        XCTAssertEqual(type, "future.event.shape")
    }

    // MARK: - Helpers

    private static func encode<E: Encodable>(_ event: E) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TNTRealtimeTests", code: 1)
        }
        return object
    }
}
