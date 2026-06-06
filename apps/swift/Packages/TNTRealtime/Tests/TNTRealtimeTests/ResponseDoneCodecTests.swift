import XCTest
@testable import TNTRealtime

/// Codec tests for the extended `response.done` event (issue #80).
///
/// Acceptance criteria:
/// - `response.done` decodes `response_id` and `status` in addition to `type`.
/// - Absent fields are tolerated (no throw on a minimal payload).
/// - Golden test against a GA `response.done` fixture asserts the new fields decode.
/// - No change to any other event's decoding; existing codec tests stay green.
final class ResponseDoneCodecTests: XCTestCase {

    // MARK: - Golden fixture: full GA response.done

    func testResponseDoneDecodesResponseIdAndStatus() throws {
        let raw = """
        {
          "type": "response.done",
          "response_id": "resp_abc123",
          "status": "completed"
        }
        """
        let event = try JSONDecoder().decode(ResponseDone.self, from: Data(raw.utf8))
        XCTAssertEqual(event.type, "response.done")
        XCTAssertEqual(event.responseId, "resp_abc123")
        XCTAssertEqual(event.status, "completed")
    }

    func testResponseDoneDecodesFailedStatus() throws {
        let raw = """
        {
          "type": "response.done",
          "response_id": "resp_xyz",
          "status": "failed"
        }
        """
        let event = try JSONDecoder().decode(ResponseDone.self, from: Data(raw.utf8))
        XCTAssertEqual(event.responseId, "resp_xyz")
        XCTAssertEqual(event.status, "failed")
    }

    // MARK: - Tolerates absent optional fields

    func testMinimalResponseDoneWithOnlyTypeSucceeds() throws {
        // A minimal server payload — only type present (status/response_id absent).
        let raw = """
        {"type":"response.done"}
        """
        let event = try JSONDecoder().decode(ResponseDone.self, from: Data(raw.utf8))
        XCTAssertEqual(event.type, "response.done")
        XCTAssertNil(event.responseId, "responseId must be nil when absent")
        XCTAssertNil(event.status, "status must be nil when absent")
    }

    func testResponseDoneWithResponseIdButNoStatus() throws {
        let raw = """
        {"type":"response.done","response_id":"resp_partial"}
        """
        let event = try JSONDecoder().decode(ResponseDone.self, from: Data(raw.utf8))
        XCTAssertEqual(event.responseId, "resp_partial")
        XCTAssertNil(event.status)
    }

    // MARK: - Dispatcher routes response.done with new fields

    func testDispatcherPreservesResponseIdAndStatusOnResponsDone() throws {
        let raw = """
        {
          "type": "response.done",
          "response_id": "resp_disp01",
          "status": "completed"
        }
        """
        let serverEvent = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .responseDone(let payload) = serverEvent else {
            XCTFail("Expected responseDone, got \(serverEvent)")
            return
        }
        XCTAssertEqual(payload.responseId, "resp_disp01")
        XCTAssertEqual(payload.status, "completed")
    }

    func testDispatcherHandlesMinimalResponseDone() throws {
        let raw = #"{"type":"response.done"}"#
        let serverEvent = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .responseDone(let payload) = serverEvent else {
            XCTFail("Expected responseDone, got \(serverEvent)")
            return
        }
        XCTAssertNil(payload.responseId)
        XCTAssertNil(payload.status)
    }

    // MARK: - Regression: no other events changed

    func testOtherEventsDecodingUnchanged() throws {
        // audio delta still works
        let audioDelta = #"{"type":"response.audio.delta","response_id":"r","item_id":"i","delta":"AAA="}"#
        let audioEvent = try RealtimeEventDecoder.decode(from: Data(audioDelta.utf8))
        guard case .responseAudioDelta(let payload) = audioEvent else {
            XCTFail("Expected responseAudioDelta, got \(audioEvent)")
            return
        }
        XCTAssertEqual(payload.delta, "AAA=")

        // error still works
        let errorRaw = #"{"type":"error","error":{"type":"t","code":"c","message":"m"}}"#
        let errorEvent = try RealtimeEventDecoder.decode(from: Data(errorRaw.utf8))
        guard case .error(let err) = errorEvent else {
            XCTFail("Expected error, got \(errorEvent)")
            return
        }
        XCTAssertEqual(err.error.code, "c")
    }
}
