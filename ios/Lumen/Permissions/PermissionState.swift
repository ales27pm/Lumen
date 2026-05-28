import Foundation

enum AssistantPermissionState: String, Codable, Sendable, Equatable {
    case notDetermined, granted, denied, restricted, unavailable, unknown
}
