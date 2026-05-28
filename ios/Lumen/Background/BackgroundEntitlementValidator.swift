import Foundation

struct EntitlementAuditWarning: Sendable, Equatable {
    let code: String
    let message: String
}

enum BackgroundEntitlementValidator {
    static let requiredTaskIDs: Set<String> = [
        TriggerScheduler.refreshIdentifier,
        TriggerScheduler.processIdentifier
    ]

    static func validate(infoDictionary: [String: Any]) -> [EntitlementAuditWarning] {
        var warnings: [EntitlementAuditWarning] = []
        let permitted = Set((infoDictionary["BGTaskSchedulerPermittedIdentifiers"] as? [String]) ?? [])
        for required in requiredTaskIDs where !permitted.contains(required) {
            warnings.append(.init(code: "missing_bg_task_id", message: "Missing BG task identifier: \(required)"))
        }

        let keyChecks = [
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
            "NSCalendarsUsageDescription",
            "NSContactsUsageDescription"
        ]
        for key in keyChecks where (infoDictionary[key] as? String)?.isEmpty != false {
            warnings.append(.init(code: "missing_usage_description", message: "Missing usage description: \(key)"))
        }
        return warnings
    }
}
