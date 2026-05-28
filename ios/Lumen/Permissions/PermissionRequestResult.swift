import Foundation

struct PermissionRequestResult: Sendable, Equatable {
    let domain: PermissionDomain
    let state: PermissionState
    let message: String
}
