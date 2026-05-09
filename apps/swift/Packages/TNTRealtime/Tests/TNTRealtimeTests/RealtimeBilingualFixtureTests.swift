import XCTest
@testable import TNTRealtime

/// Bilingual fixture replay over `MockTransport`. Each fixture replays
/// a recorded server response (English, Mandarin, code-switch) and
/// asserts that the client's *outbound* event sequence stays identical
/// — the client never reads response content, only forwards mic audio
/// and commits, so the bilingual scope must not leak into outbound.
///
/// Fixtures live at `Tests/TNTRealtimeTests/Fixtures/{pure-en,pure-zh,code-switch}.json`
/// and are bundled via `Bundle.module` (see `Package.swift`).
final class RealtimeBilingualFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        let name: String
        let description: String
        let inbound: [String]
        let expected_outbound_types: [String]
    }

    func testPureEnglishFixture() async throws {
        try await replay(named: "pure-en")
    }

    func testPureMandarinFixture() async throws {
        try await replay(named: "pure-zh")
    }

    func testCodeSwitchFixture() async throws {
        try await replay(named: "code-switch")
    }

    /// The system prompt copy must be referenced from a test so that
    /// any change to it shows up in code review (per M0/S9 acceptance).
    func testV0SystemPromptCoversBilingualAndOperationalTone() {
        let prompt = RealtimePrompts.v0System
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("English"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Mandarin"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Voice Turn"))
        XCTAssertFalse(prompt.isEmpty)
    }

    func testBilingualSessionUpdateCarriesCanonicalShape() throws {
        let update = SessionUpdate.bilingualV0()
        let json = try JSONEncoder().encode(update)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "session.update")
        let session = object?["session"] as? [String: Any]
        XCTAssertNotNil(session)
        XCTAssertEqual(session?["voice"] as? String, "alloy")
        XCTAssertEqual(session?["language"] as? [String], ["en", "zh"])
        XCTAssertEqual(session?["modalities"] as? [String], ["audio", "text"])
        XCTAssertEqual(session?["instructions"] as? String, RealtimePrompts.v0System)
    }

    func testBilingualSessionUpdateRespectsVoiceOverride() throws {
        let update = SessionUpdate.bilingualV0(voice: "verse")
        let json = try JSONEncoder().encode(update)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let session = object?["session"] as? [String: Any]
        XCTAssertEqual(session?["voice"] as? String, "verse")
    }

    // MARK: - Helpers

    private func replay(named name: String) async throws {
        let fixture = try loadFixture(named: name)

        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport)
        try await client.connect()

        // Outbound — exactly the M0/S9 contract: session.update first,
        // then audio frames, then commit + create.
        try await client.send(SessionUpdate.bilingualV0())
        try await client.send(InputAudioBufferAppend(audio: "AAA="))
        try await client.send(InputAudioBufferAppend(audio: "BBB="))
        try await client.send(InputAudioBufferCommit())
        try await client.send(ResponseCreate(response: .init(modalities: ["audio", "text"])))

        // Inject the recorded server-side responses.
        for raw in fixture.inbound {
            transport.enqueueText(raw)
        }

        // Drain until the recorded `response.done` is seen so the
        // client has fully consumed the fixture before we assert.
        var iterator = client.inbound.makeAsyncIterator()
        var sawDone = false
        let deadline = Date().addingTimeInterval(2.0)
        while !sawDone, Date() < deadline {
            guard let event = await iterator.next() else { break }
            if case .responseDone = event { sawDone = true }
        }
        XCTAssertTrue(sawDone, "Fixture \(name) — client did not see response.done.")

        // Assert outbound type sequence — this is the bilingual scope's
        // promise: client behaviour does not depend on response language.
        let actualTypes = transport.sendLog.compactMap(Self.extractType(from:))
        XCTAssertEqual(
            actualTypes,
            fixture.expected_outbound_types,
            "Fixture \(name) — outbound event types diverged from the recorded contract."
        )

        await client.disconnect()
    }

    private func loadFixture(named name: String) throws -> Fixture {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            throw NSError(domain: "TNTRealtimeTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture \(name).json not found in test bundle.",
            ])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private static func extractType(from rawJson: String) -> String? {
        guard let data = rawJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["type"] as? String
    }
}
