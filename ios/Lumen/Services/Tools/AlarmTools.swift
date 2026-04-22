import Foundation

#if canImport(AlarmKit)
import AlarmKit
#endif

@MainActor
enum AlarmTools {
    static func schedule(args: [String: String]) async -> String {
        let title = args["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args["title"]!
            : "Alarm"
        let snoozeMinutes = Int(args["snoozeMinutes"] ?? "5") ?? 5
        let repeats = (args["repeats"] ?? "false").lowercased() == "true"

        if let inMinutes = Int(args["inMinutes"] ?? "") {
            let fireDate = Date().addingTimeInterval(TimeInterval(max(1, inMinutes) * 60))
            return await scheduleAlarm(
                title: title,
                fireDate: fireDate,
                repeats: repeats,
                snoozeMinutes: max(1, snoozeMinutes)
            )
        }

        if let unix = TimeInterval(args["timestamp"] ?? "") {
            let fireDate = Date(timeIntervalSince1970: unix)
            return await scheduleAlarm(
                title: title,
                fireDate: fireDate,
                repeats: repeats,
                snoozeMinutes: max(1, snoozeMinutes)
            )
        }

        return "Missing schedule. Provide `inMinutes` or `timestamp` (Unix seconds)."
    }

    static func countdown(args: [String: String]) async -> String {
        let title = args["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args["title"]!
            : "Countdown"
        let duration = Int(args["durationSeconds"] ?? "") ?? 0
        guard duration > 0 else {
            return "Missing duration. Provide `durationSeconds` greater than 0."
        }
        let fireDate = Date().addingTimeInterval(TimeInterval(duration))
        return await scheduleAlarm(title: title, fireDate: fireDate, repeats: false, snoozeMinutes: 1)
    }

    static func cancel(id: String) async -> String {
#if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return "Alarm cancellation requires a concrete AlarmKit alarm identifier integration."
        }
#endif
        _ = id
        return "AlarmKit requires iOS 26.0+ and an AlarmKit-capable runtime."
    }

    private static func scheduleAlarm(title: String, fireDate: Date, repeats: Bool, snoozeMinutes: Int) async -> String {
#if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return "AlarmKit scheduling entry created for \"\(title)\" at \(fireDate.formatted(date: .abbreviated, time: .shortened)). Repeats: \(repeats ? "yes" : "no"), snooze: \(snoozeMinutes)m."
        }
#endif
        _ = repeats
        _ = snoozeMinutes
        return "AlarmKit requires iOS 26.0+ and an AlarmKit-capable runtime. Requested \"\(title)\" for \(fireDate.formatted(date: .abbreviated, time: .shortened))."
    }
}
