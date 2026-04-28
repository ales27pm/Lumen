import Foundation

nonisolated enum AgentJSONValue: Sendable, Hashable, Codable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])
    case null

    var description: String { stringValue }

    static func parse(_ value: Any) -> AgentJSONValue? {
        if value is NSNull { return .null }
        if let string = value as? String { return .string(string) }
        if let bool = value as? Bool { return .bool(bool) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let array = value as? [Any] {
            let parsed = array.compactMap(AgentJSONValue.parse)
            return parsed.count == array.count ? .array(parsed) : nil
        }
        if let object = value as? [String: Any] {
            var parsed: [String: AgentJSONValue] = [:]
            for (key, innerValue) in object {
                guard let inner = AgentJSONValue.parse(innerValue) else { return nil }
                parsed[key] = inner
            }
            return .object(parsed)
        }
        return nil
    }

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
        case .array(let values):
            return values.jsonRenderedString ?? "[" + values.map(\.stringValue).joined(separator: ",") + "]"
        case .object(let values):
            if let rendered = values.jsonRenderedString { return rendered }
            let fallback = values.keys.sorted().map { key in
                let value = values[key]?.stringValue ?? "null"
                return "\"\(key)\":\(value)"
            }.joined(separator: ",")
            return "{\(fallback)}"
        case .null:
            return "null"
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            guard value.isFinite else { return nil }
            return Int(exactly: value) ?? Int(value)
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
            return value != 0
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
        foundationObject
    }

    var jsonString: String? {
        switch self {
        case .array(let values):
            return values.jsonRenderedString
        case .object(let values):
            return values.jsonRenderedString
        default:
            guard JSONSerialization.isValidJSONObject(["value": foundationObject]),
                  let data = try? JSONSerialization.data(withJSONObject: ["value": foundationObject], options: [.sortedKeys]),
                  let wrapped = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rendered = wrapped["value"] else {
                return nil
            }
            if let string = rendered as? String { return "\"\(string)\"" }
            return String(describing: rendered)
        }
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
}

typealias AgentJSONArguments = [String: AgentJSONValue]

extension Dictionary where Key == String, Value == AgentJSONValue {
    init(stringDictionary: [String: String]) {
        self = stringDictionary.reduce(into: [:]) { partialResult, element in
            partialResult[element.key] = .string(element.value)
        }
    }

    var stringCoerced: [String: String] {
        reduce(into: [String: String]()) { partialResult, element in
            partialResult[element.key] = element.value.stringValue
        }
    }

    fileprivate var jsonRenderedString: String? {
        let foundationObject = reduce(into: [String: Any]()) { partialResult, element in
            partialResult[element.key] = element.value.foundationObject
        }
        guard JSONSerialization.isValidJSONObject(foundationObject),
              let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
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

extension Array where Element == AgentJSONValue {
    fileprivate var jsonRenderedString: String? {
        let foundationObject = map(\.foundationObject)
        guard JSONSerialization.isValidJSONObject(foundationObject),
              let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}

private extension AgentJSONValue {
    var foundationObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return NSNumber(value: value)
        case .bool(let value):
            return NSNumber(value: value)
        case .array(let values):
            return values.map(\.foundationObject)
        case .object(let value):
            return value.reduce(into: [String: Any]()) { partialResult, element in
                partialResult[element.key] = element.value.foundationObject
            }
        case .null:
            return NSNull()
        }
    }
}
