import Foundation

nonisolated enum AgentJSONValue: Sendable, Hashable, Codable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])
    case null

    var description: String { stringValue }

    var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.isFinite, value.rounded() == value {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array, .object:
            return jsonString ?? ""
        case .null:
            return ""
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.isFinite else { return nil }
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool(let value):
            return value ? 1 : 0
        case .array, .object, .null:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value == 0 ? false : true
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1": return true
            case "false", "no", "n", "0": return false
            default: return nil
            }
        case .array, .object, .null:
            return nil
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .array(let values): values.map(\.jsonObject)
        case .object(let values): values.mapValues { $0.jsonObject }
        case .null: NSNull()
        }
    }

    var jsonString: String? {
        guard JSONSerialization.isValidJSONObject(jsonObject) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

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
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AgentJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        case .null: try container.encodeNil()
        }
    }

    static func parse(_ raw: Any) -> AgentJSONValue? {
        switch raw {
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Int8:
            return .number(Double(value))
        case let value as Int16:
            return .number(Double(value))
        case let value as Int32:
            return .number(Double(value))
        case let value as Int64:
            return .number(Double(value))
        case let value as UInt:
            return .number(Double(value))
        case let value as UInt8:
            return .number(Double(value))
        case let value as UInt16:
            return .number(Double(value))
        case let value as UInt32:
            return .number(Double(value))
        case let value as UInt64:
            return .number(Double(value))
        case let value as Float:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(value.compactMap { parse($0) })
        case let value as [String: Any]:
            var object: [String: AgentJSONValue] = [:]
            for (key, child) in value {
                guard let parsed = parse(child) else { return nil }
                object[key] = parsed
            }
            return .object(object)
        case is NSNull:
            return .null
        default:
            return nil
        }
    }
}

nonisolated typealias AgentJSONArguments = [String: AgentJSONValue]

nonisolated extension Dictionary where Key == String, Value == AgentJSONValue {
    var stringCoerced: [String: String] {
        mapValues { $0.stringValue }
    }

    func string(_ key: String, default defaultValue: String = "") -> String {
        self[key]?.stringValue ?? defaultValue
    }

    func optionalString(_ key: String) -> String? {
        guard let value = self[key] else { return nil }
        let string = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        self[key]?.intValue ?? defaultValue
    }
}
