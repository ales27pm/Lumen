import Foundation
import Observation

/// Ephemeral, non-persisted UI state. Reset every launch. Do not persist any of
/// these to disk.
@Observable
final class RuntimeState {
    /// Whether a chat / agent generation is currently streaming.
    var isGenerating: Bool = false

    /// Whether the app has verified user notification permission for triggers.
    /// `nil` means not yet asked.
    var notificationPermissionGranted: Bool?
}
