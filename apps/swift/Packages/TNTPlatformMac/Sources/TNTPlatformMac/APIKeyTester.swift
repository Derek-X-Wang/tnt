// APIKeyTester — verifies an OpenAI BYOK key by calling
// `GET https://api.openai.com/v1/models`. The protocol exists so the
// SwiftUI BYOK form can drive deterministic tests later (a stub
// `APIKeyTester` lets us flip Test → success/failure without touching
// the network); the concrete `OpenAIAPIKeyTester` is what production
// uses.

import Foundation

public enum APIKeyTestError: Error, Equatable, Sendable {
    case invalidKey
    case rateLimited
    case network(String)
    case unexpectedStatus(Int)
}

public protocol APIKeyTester: Sendable {
    func test(key: String) async -> Result<Void, APIKeyTestError>
}

/// Production-backed tester. Calls `GET /v1/models` because (a) the
/// endpoint is cheap, (b) it returns 401 immediately on bad keys, and
/// (c) it doesn't bill the User a token for the round-trip.
public struct OpenAIAPIKeyTester: APIKeyTester {

    private let endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/models")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    public func test(key: String) async -> Result<Void, APIKeyTestError> {
        guard !key.isEmpty else { return .failure(.invalidKey) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.network("non-HTTP response"))
            }
            switch http.statusCode {
            case 200..<300: return .success(())
            case 401:       return .failure(.invalidKey)
            case 429:       return .failure(.rateLimited)
            default:        return .failure(.unexpectedStatus(http.statusCode))
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
