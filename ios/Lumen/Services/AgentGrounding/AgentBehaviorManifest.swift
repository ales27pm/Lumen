import Foundation

public struct AgentBehaviorManifest: Codable, Hashable {
    public let schemaVersion: String
    public let app: ManifestAppInfo
    public let sourceIntegrity: ManifestSourceIntegrity?
    public let fleet: ManifestFleet
    public let tools: [RuntimeToolDefinition]
    public let intents: [ManifestIntent]
    public let routingMatrix: [ManifestRoutingEntry]
    public let memory: ManifestMemory?
    public let sentinels: ManifestSentinels
}

public struct ManifestAppInfo: Codable, Hashable {
    public let name: String
    public let bundleIdentifier: String?
    public let buildVersion: String?
    public let generatedAt: String?
}

public struct ManifestSourceIntegrity: Codable, Hashable {
    public let commit: String?
    public let files: [ManifestSourceFileHash]
}

public struct ManifestSourceFileHash: Codable, Hashable {
    public let path: String
    public let sha256: String
}

public struct ManifestFleet: Codable, Hashable {
    public let contractVersion: String
    public let slots: [ManifestModelSlot]
}

public struct ManifestModelSlot: Codable, Hashable {
    public let id: String
    public let role: String
    public let modelFamily: String?
    public let responsibilities: [String]
}

public struct ManifestIntent: Codable, Hashable {
    public let id: String
    public let allowedToolIDs: [String]
}

public struct ManifestRoutingEntry: Codable, Hashable {
    public let intent: String
    public let allowedTools: [String]
    public let forbiddenTools: [String]
}

public struct ManifestMemory: Codable, Hashable {
    public let scopes: [String]
    public let freshnessClasses: [ManifestFreshnessClass]
}

public struct ManifestFreshnessClass: Codable, Hashable {
    public let id: String
    public let ttlSeconds: Int?
    public let durable: Bool?
}

public struct ManifestSentinels: Codable, Hashable {
    public let forbiddenInUserOutput: [String]
}

public struct RuntimeToolDefinition: Codable, Hashable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let requiresApproval: Bool
    public let permissionKey: String?
    public let arguments: [RuntimeToolArgument]

    public init(id: String, displayName: String? = nil, description: String? = nil, requiresApproval: Bool = false, permissionKey: String? = nil, arguments: [RuntimeToolArgument] = []) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.requiresApproval = requiresApproval
        self.permissionKey = permissionKey
        self.arguments = arguments
    }
}

public struct RuntimeToolArgument: Codable, Hashable {
    public let name: String
    public let type: String
    public let required: Bool

    public init(name: String, type: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.required = required
    }
}
