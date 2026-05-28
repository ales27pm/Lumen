import Foundation

enum ToolCategory: String, Codable, Sendable { case readOnly, permissionRead, userVisibleAction, sensitiveAction, destructiveAction, externalNetwork }
