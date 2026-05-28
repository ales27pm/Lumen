import Foundation

enum PermissionState: String, Codable, Sendable, Equatable {
    case notDetermined, granted, denied, restricted, unavailable, unknown
}
