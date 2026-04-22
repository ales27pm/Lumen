import Foundation

/// Thin dispatcher that routes a tool ID + arguments to the appropriate
/// domain-specific service. All actual logic lives in `Services/Tools/*.swift`.
/// The public contract (`ToolExecutor.shared.execute(id, arguments:)`) is
/// preserved so the rest of the app keeps working unchanged.
@MainActor
final class ToolExecutor {
    static let shared = ToolExecutor()

    private init() {}

    func execute(_ toolID: String, arguments: [String: String]) async -> String {
        switch toolID {
        // Calendar / Reminders
        case "calendar.create":
            return await CalendarTools.createEvent(
                title: arguments["title"] ?? "New Event",
                startsInMinutes: Int(arguments["startsInMinutes"] ?? "60") ?? 60
            )
        case "calendar.list":
            return await CalendarTools.listEvents()
        case "reminders.create":
            return await CalendarTools.createReminder(title: arguments["title"] ?? "Reminder")
        case "reminders.list":
            return await CalendarTools.listReminders()

        // Contacts / Communication
        case "contacts.search":
            return await ContactsTools.searchContacts(query: arguments["query"] ?? "")
        case "messages.draft":
            return await ContactsTools.composeMessage(arguments: arguments)
        case "mail.draft":
            return await ContactsTools.composeMail(arguments: arguments)
        case "phone.call":
            return await ContactsTools.call(number: arguments["number"] ?? "")

        // Location / Maps
        case "location.current":
            return await LocationTools.currentLocation()
        case "maps.directions":
            return LocationTools.openDirections(destination: arguments["destination"] ?? "")
        case "maps.search":
            return await LocationTools.searchNearby(query: arguments["query"] ?? "")

        // Photos / Camera
        case "photos.search":
            return await PhotosTools.searchPhotos(query: arguments["query"] ?? "")
        case "camera.capture":
            return await PhotosTools.captureImage()

        // Health / Motion
        case "health.summary":
            return await HealthTools.healthSummary()
        case "motion.activity":
            return await MotionTools.shared.motionActivity()

        // Web / Files
        case "web.search":
            return await WebTools.webSearch(query: arguments["query"] ?? "")
        case "web.fetch":
            return await WebTools.webFetch(url: arguments["url"] ?? "")
        case "files.read":
            return await FilesTools.readImportedFile(name: arguments["name"] ?? "")

        // Memory / RAG
        case "memory.save":
            return await MemoryTools.save(
                content: arguments["content"] ?? "",
                kind: arguments["kind"] ?? "fact"
            )
        case "memory.recall":
            return await MemoryTools.recall(query: arguments["query"] ?? "")
        case "rag.search":
            return await MemoryTools.ragSearch(
                query: arguments["query"] ?? "",
                limit: Int(arguments["limit"] ?? "5") ?? 5
            )
        case "rag.index_files":
            return await MemoryTools.ragIndexFiles()
        case "rag.index_photos":
            return await MemoryTools.ragIndexPhotos(months: Int(arguments["months"] ?? "6") ?? 6)

        // Triggers
        case "trigger.create":
            return await TriggerTools.create(args: arguments)
        case "trigger.list":
            return await TriggerTools.list()
        case "trigger.cancel":
            return await TriggerTools.cancel(title: arguments["title"] ?? arguments["id"] ?? "")

        // AlarmKit
        case "alarm.authorization_status":
            return await AlarmTools.authorizationStatus()
        case "alarm.request_authorization":
            return await AlarmTools.requestAuthorization()
        case "alarm.schedule":
            return await AlarmTools.schedule(args: arguments)
        case "alarm.countdown":
            return await AlarmTools.countdown(args: arguments)
        case "alarm.list":
            return await AlarmTools.list()
        case "alarm.pause":
            return await AlarmTools.pause(id: arguments["id"] ?? "")
        case "alarm.resume":
            return await AlarmTools.resume(id: arguments["id"] ?? "")
        case "alarm.stop":
            return await AlarmTools.stop(id: arguments["id"] ?? "")
        case "alarm.snooze":
            return await AlarmTools.snooze(id: arguments["id"] ?? "")
        case "alarm.cancel":
            return await AlarmTools.cancel(id: arguments["id"] ?? arguments["title"] ?? "")

        default:
            return "Unknown tool: \(toolID)"
        }
    }
}
