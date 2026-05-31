// JSONValue — a recursive Codable enum that can represent any JSON
// value. Used for the `parameters` field of `RealtimeTool`, which
// carries an arbitrary JSON Schema object. Standard `Codable` cannot
// express `Any`, so this wrapper provides a fully round-tripping
// alternative that compiles without unsafe casts.

import Foundation

/// A type-safe, fully Codable representation of any JSON value.
/// Used wherever the wire schema permits arbitrary JSON (e.g.
/// JSON Schema `parameters` objects in Realtime tool definitions).
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: JSONValue])
    case array([JSONValue])

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else {
            let dict = try container.decode([String: JSONValue].self)
            self = .object(dict)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let b):    try container.encode(b)
        case .number(let n):  try container.encode(n)
        case .string(let s):  try container.encode(s)
        case .array(let a):   try container.encode(a)
        case .object(let o):  try container.encode(o)
        }
    }

    // MARK: - Convenience constructors

    /// A convenience for building JSON Schema "object" nodes inline.
    public static func schema(
        type: String,
        properties: [String: JSONValue]? = nil,
        required: [String]? = nil,
        additionalProperties: Bool? = nil
    ) -> JSONValue {
        var obj: [String: JSONValue] = ["type": .string(type)]
        if let props = properties { obj["properties"] = .object(props) }
        if let req = required { obj["required"] = .array(req.map { .string($0) }) }
        if let ap = additionalProperties { obj["additionalProperties"] = .bool(ap) }
        return .object(obj)
    }
}
