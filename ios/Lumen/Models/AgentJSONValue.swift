import Foundation

nonisolated enum AgentJSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])
    case null

    static func parse(_ value: Any) -> AgentJSONValue? {
        if value is NSNull { return .null }
        if let str = value as? String { return .string(str) }
        if let bool = value as? Bool { return .bool(bool) }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            return .number(num.doubleValue)
        }
        if let arr = value as? [Any] {
            let parsed = arr.compactMap(AgentJSONValue.parse)
            return parsed.count == arr.count ? .array(parsed) : nil
        }
        if let obj = value as? [String: Any] {
            var parsed: [String: AgentJSONValue] = [:]
            for (key, innerValue) in obj {
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
            let isWhole = value.rounded(.towardZero) == value
            if isWhole { return String(Int(value)) }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return "[" + values.map(\.stringValue).joined(separator: ",") + "]"
        case .object(let values):
            let body = values.keys.sorted().map { key in
                let value = values[key]?.stringValue ?? ""
                return "\(key):\(value)"
            }.joined(separator: ",")
            return "{" + body + "}"
        case .null:
            return "null"
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            if value.rounded(.towardZero) == value { return Int(value) }
            return nil
        case .string(let value):
            return Int(value)
        case .bool(let value):
            return value ? 1 : 0
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" { return true }
            if normalized == "false" { return false }
            return nil
        case .number(let value):
            return value != 0
        default:
            return nil
        }
    }
}

typealias AgentJSONArguments = [String: AgentJSONValue]

extension Dictionary where Key == String, Value == AgentJSONValue {
    var stringCoerced: [String: String] {
        reduce(into: [String: String]()) { partialResult, element in
            partialResult[element.key] = element.value.stringValue
        }
    }
}
