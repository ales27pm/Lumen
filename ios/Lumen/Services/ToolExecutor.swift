import Foundation

nonisolated enum ToolExecutionApproval: Sendable {
    case autonomous
    case userApproved
}

@MainActor
final class ToolExecutor {
    static let shared = ToolExecutor()

    private init() {}

    func execute(
        _ toolID: String,
        arguments: AgentJSONArguments,
        approval: ToolExecutionApproval = .autonomous
    ) async -> String {
        let id = ToolRouteGuard.canonicalToolID(toolID)
        let stringArguments = arguments.stringCoerced

        guard ToolRouteGuard.canExecuteTool(id, arguments: stringArguments, approval: approval) else {
            return ToolRouteGuard.approvalRequiredMessage(for: id)
        }

        switch id {
        case "calendar.create":
            return await CalendarTools.createEvent(
                title: stringArguments["title"] ?? "New Event",
                startsInMinutes: Int(stringArguments["startsInMinutes"] ?? "60") ?? 60
            )
        case "calendar.list":
            return await CalendarTools.listEvents()
        case "reminders.create":
            return await CalendarTools.createReminder(title: stringArguments["title"] ?? "Reminder")
        case "reminders.list":
            return await CalendarTools.listReminders()
        case "contacts.search":
            return await ContactsTools.searchContacts(query: stringArguments["query"] ?? "")
        case "messages.draft":
            return await ContactsTools.composeMessage(arguments: stringArguments)
        case "mail.draft":
            return await ContactsTools.composeMail(arguments: stringArguments)
        case "phone.call":
            return await ContactsTools.call(number: stringArguments["number"] ?? "")
        case "location.current":
            return await LocationTools.currentLocation()
        case "weather":
            return await WeatherTools.currentWeather(location: stringArguments["location"] ?? stringArguments["city"] ?? stringArguments["query"])
        case "maps.directions":
            return LocationTools.openDirections(destination: stringArguments["destination"] ?? "")
        case "maps.search":
            let query = stringArguments["query"] ?? ""
            if ToolRouteGuard.shouldUseWebSearchInsteadOfNearbySearch(query: query) {
                return await WebTools.webSearch(query: query)
            }
            return await LocationTools.searchNearby(query: query)
        case "photos.search":
            return await PhotosTools.searchPhotos(query: stringArguments["query"] ?? "")
        case "camera.capture":
            return await PhotosTools.captureImage()
        case "health.summary":
            return await HealthTools.healthSummary()
        case "motion.activity":
            return await MotionTools.shared.motionActivity()
        case "web.search":
            return await WebTools.webSearch(query: stringArguments["query"] ?? "")
        case "web.fetch":
            return await WebTools.webFetch(url: stringArguments["url"] ?? "")
        case "files.read":
            return await FilesTools.readImportedFile(name: stringArguments["name"] ?? "")
        case "memory.save":
            return await MemoryTools.save(content: stringArguments["content"] ?? "", kind: stringArguments["kind"] ?? "fact")
        case "memory.recall":
            return await MemoryTools.recall(query: stringArguments["query"] ?? "")
        case "rag.search":
            return await MemoryTools.ragSearch(query: stringArguments["query"] ?? "", limit: Int(stringArguments["limit"] ?? "5") ?? 5)
        case "rag.index_files":
            return await MemoryTools.ragIndexFiles()
        case "rag.index_photos":
            return await MemoryTools.ragIndexPhotos(months: Int(stringArguments["months"] ?? "6") ?? 6)
        case "trigger.create":
            return await TriggerTools.create(args: stringArguments)
        case "trigger.list":
            return await TriggerTools.list()
        case "trigger.cancel":
            return await TriggerTools.cancel(title: stringArguments["title"] ?? stringArguments["id"] ?? "")
        case "alarm.authorization_status":
            return await AlarmTools.authorizationStatus()
        case "alarm.request_authorization":
            return await AlarmTools.requestAuthorization()
        case "alarm.schedule":
            return await AlarmTools.schedule(args: stringArguments)
        case "alarm.countdown":
            return await AlarmTools.countdown(args: stringArguments)
        case "alarm.list":
            return await AlarmTools.list()
        case "alarm.pause":
            return await AlarmTools.pause(id: stringArguments["id"] ?? "")
        case "alarm.resume":
            return await AlarmTools.resume(id: stringArguments["id"] ?? "")
        case "alarm.stop":
            return await AlarmTools.stop(id: stringArguments["id"] ?? "")
        case "alarm.snooze":
            return await AlarmTools.snooze(id: stringArguments["id"] ?? "")
        case "alarm.cancel":
            return await AlarmTools.cancel(id: stringArguments["id"] ?? stringArguments["title"] ?? "")
        default:
            return "Unknown tool: \(toolID). Available weather/search tools are: weather, web.search, maps.search, location.current."
        }
    }

    func execute(
        _ toolID: String,
        arguments: [String: String],
        approval: ToolExecutionApproval = .autonomous
    ) async -> String {
        let typedArguments = AgentJSONArguments(stringDictionary: arguments)
        return await execute(toolID, arguments: typedArguments, approval: approval)
    }

}

nonisolated enum ToolRouteGuard {
    static func canonicalToolID(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch id {
        case "weather", "weather.current", "current.weather", "forecast.current", "weather.get", "get_weather":
            return "weather"
        case "search", "internet.search", "web", "web_search", "browser.search":
            return "web.search"
        case "maps", "map.search", "nearby.search", "local.search", "places.search":
            return "maps.search"
        case "location", "gps", "current.location", "location.get":
            return "location.current"
        default:
            return id
        }
    }

    static func canExecuteTool(_ canonicalToolID: String, arguments: [String: String], approval: ToolExecutionApproval) -> Bool {
        if requiresUserApproval(canonicalToolID), approval != .userApproved {
            return false
        }

        if canonicalToolID == "calendar.create" {
            return isExplicitCalendarCreateIntent(arguments: arguments)
        }
        return true
    }

    static func approvalRequiredMessage(for canonicalToolID: String) -> String {
        if canonicalToolID == "calendar.create" {
            return "Calendar event creation requires explicit user approval. I did not create an event."
        }
        return "This tool requires explicit user approval before it can run: \(canonicalToolID)."
    }

    static func requiresUserApproval(_ canonicalToolID: String) -> Bool {
        ToolRegistry.find(id: canonicalToolID)?.requiresApproval ?? false
    }

    static func isExplicitCalendarCreateIntent(arguments: [String: String]) -> Bool {
        let title = arguments["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return false }

        let startsIn = arguments["startsInMinutes"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasValidStart = Int(startsIn).map { $0 >= 0 } ?? false
        guard hasValidStart else { return false }

        let suspiciousGreetingTitles = ["hi", "hello", "hey", "hi lumen", "hello lumen", "hey lumen"]
        return !suspiciousGreetingTitles.contains(title.lowercased())
    }

    static func shouldUseWebSearchInsteadOfNearbySearch(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let localIntentMarkers = [
            "near me", "nearby", "closest", "around me", "around here", "in my area",
            "directions", "route to", "open maps", "address of", "store near",
            "restaurant near", "coffee near", "gas station", "pharmacy near"
        ]
        if localIntentMarkers.contains(where: { normalized.contains($0) }) {
            return false
        }

        let webIntentMarkers = [
            "diy", "how to", "tutorial", "guide", "research", "internet", "web",
            "article", "manual", "documentation", "plans", "blueprint", "build"
        ]
        if webIntentMarkers.contains(where: { normalized.contains($0) }) {
            return true
        }

        if normalized.hasPrefix("search ") || normalized.hasPrefix("search for ") || normalized.hasPrefix("look up ") {
            return true
        }

        return false
    }
}
