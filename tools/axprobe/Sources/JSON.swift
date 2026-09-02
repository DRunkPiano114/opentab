import Foundation

/// Minimal JSON tree used for every file this tool writes.
///
/// Output is encoded with `.sortedKeys`, so two runs against an unchanged app
/// produce byte-identical files and `git diff` shows only real changes.
enum JSON: Encodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    static func string(_ value: String?) -> JSON {
        value.map(JSON.string) ?? .null
    }

    /// Non-finite doubles have no JSON representation; keep them visible as text
    /// instead of silently coercing them to 0.
    static func number(_ value: Double) -> JSON {
        value.isFinite ? .double(value) : .string(String(describing: value))
    }

    static func strings(_ values: [String]) -> JSON {
        .array(values.map(JSON.string))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
