import Foundation

enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value,
              abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// A string written as `ManifestCodec.encodeDate` writes one.
    var dateValue: Date? { stringValue.flatMap(ManifestCodec.parseDate) }

    var uuidValue: UUID? { stringValue.flatMap(UUID.init(uuidString:)) }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func serialized(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension [String: JSONValue] {
    /// When `key` was last changed, from the stamps kept under "changedAt", which older builds keep as an unknown key.
    func changedAt(_ key: String) -> Date? {
        self["changedAt"]?[key]?.dateValue
    }

    mutating func setChangedAt(_ date: Date?, for key: String) {
        var stamps = self["changedAt"]?.objectValue ?? [:]
        stamps[key] = date.map(ManifestCodec.encodeDate)
        self["changedAt"] = stamps.isEmpty ? nil : .object(stamps)
    }
}
