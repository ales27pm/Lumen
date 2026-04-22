import Foundation
import SwiftUI

nonisolated struct ToolDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: ToolCategory
    let description: String
    let icon: String
    let tint: String
    let requiresApproval: Bool
    let permissionKey: String?

    var color: Color {
        switch tint {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "pink": .pink
        case "purple": .purple
        case "red": .red
        case "yellow": .yellow
        case "mint": .mint
        case "indigo": .indigo
        case "teal": .teal
        default: .cyan
        }
    }
}

nonisolated enum ToolCategory: String, CaseIterable, Sendable {
    case productivity = "Productivity"
    case communication = "Communication"
    case location = "Location"
    case media = "Media"
    case health = "Health & Motion"
    case knowledge = "Knowledge"
}

nonisolated enum ToolRegistry {
    static let all: [ToolDefinition] = [
        ToolDefinition(id: "calendar.create", name: "Create Event", category: .productivity, description: "Add an event to your calendar.", icon: "calendar.badge.plus", tint: "red", requiresApproval: true, permissionKey: "NSCalendarsFullAccessUsageDescription"),
        ToolDefinition(id: "calendar.list", name: "List Events", category: .productivity, description: "Read upcoming events.", icon: "calendar", tint: "red", requiresApproval: false, permissionKey: "NSCalendarsFullAccessUsageDescription"),
        ToolDefinition(id: "reminders.create", name: "Add Reminder", category: .productivity, description: "Create a new reminder.", icon: "checklist", tint: "orange", requiresApproval: true, permissionKey: "NSRemindersFullAccessUsageDescription"),
        ToolDefinition(id: "reminders.list", name: "List Reminders", category: .productivity, description: "Read pending reminders.", icon: "list.bullet.rectangle", tint: "orange", requiresApproval: false, permissionKey: "NSRemindersFullAccessUsageDescription"),
        ToolDefinition(id: "contacts.search", name: "Search Contacts", category: .communication, description: "Find a contact by name.", icon: "person.crop.circle.fill", tint: "blue", requiresApproval: false, permissionKey: "NSContactsUsageDescription"),
        ToolDefinition(id: "messages.draft", name: "Draft Message", category: .communication, description: "Compose an iMessage draft.", icon: "message.fill", tint: "green", requiresApproval: true, permissionKey: nil),
        ToolDefinition(id: "mail.draft", name: "Draft Email", category: .communication, description: "Compose an email draft.", icon: "envelope.fill", tint: "indigo", requiresApproval: true, permissionKey: nil),
        ToolDefinition(id: "phone.call", name: "Start Call", category: .communication, description: "Open the phone dialer.", icon: "phone.fill", tint: "green", requiresApproval: true, permissionKey: nil),
        ToolDefinition(id: "location.current", name: "Current Location", category: .location, description: "Get your GPS location.", icon: "location.fill", tint: "teal", requiresApproval: false, permissionKey: "NSLocationWhenInUseUsageDescription"),
        ToolDefinition(id: "maps.directions", name: "Get Directions", category: .location, description: "Open Maps with directions.", icon: "map.fill", tint: "teal", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "photos.search", name: "Search Photos", category: .media, description: "Find photos in your library.", icon: "photo.on.rectangle.angled", tint: "purple", requiresApproval: false, permissionKey: "NSPhotoLibraryUsageDescription"),
        ToolDefinition(id: "camera.capture", name: "Capture Image", category: .media, description: "Take a photo with the camera.", icon: "camera.fill", tint: "pink", requiresApproval: true, permissionKey: "NSCameraUsageDescription"),
        ToolDefinition(id: "health.summary", name: "Health Summary", category: .health, description: "Read steps, sleep, heart rate.", icon: "heart.text.square.fill", tint: "red", requiresApproval: false, permissionKey: "NSHealthShareUsageDescription"),
        ToolDefinition(id: "motion.activity", name: "Motion Activity", category: .health, description: "Detect walking, running, etc.", icon: "figure.walk", tint: "mint", requiresApproval: false, permissionKey: "NSMotionUsageDescription"),
        ToolDefinition(id: "maps.search", name: "Search Nearby", category: .location, description: "Find nearby places by query (coffee, pharmacy…).", icon: "mappin.and.ellipse", tint: "teal", requiresApproval: false, permissionKey: "NSLocationWhenInUseUsageDescription"),
        ToolDefinition(id: "web.search", name: "Web Search", category: .knowledge, description: "Search the web for fresh information.", icon: "globe", tint: "blue", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "web.fetch", name: "Fetch URL", category: .knowledge, description: "Fetch and read a web page.", icon: "link", tint: "blue", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "files.read", name: "Read File", category: .knowledge, description: "Read a previously imported document.", icon: "doc.text.fill", tint: "yellow", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "memory.save", name: "Save Memory", category: .knowledge, description: "Store a fact for future recall.", icon: "brain.head.profile", tint: "purple", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "memory.recall", name: "Recall Memory", category: .knowledge, description: "Search stored memories.", icon: "sparkle.magnifyingglass", tint: "purple", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "rag.search", name: "Search Personal Data", category: .knowledge, description: "Semantic search across your indexed files, PDFs, notes, and photo metadata.", icon: "doc.text.magnifyingglass", tint: "yellow", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "rag.index_files", name: "Reindex Files", category: .knowledge, description: "Rebuild the index for imported files and PDFs.", icon: "arrow.triangle.2.circlepath.doc.on.clipboard", tint: "yellow", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "rag.index_photos", name: "Reindex Photos", category: .knowledge, description: "Rebuild the monthly photo metadata index.", icon: "photo.stack", tint: "purple", requiresApproval: false, permissionKey: "NSPhotoLibraryUsageDescription"),
        ToolDefinition(id: "trigger.create", name: "Schedule Agent Run", category: .productivity, description: "Schedule a background agent run at a time or interval.", icon: "alarm", tint: "orange", requiresApproval: true, permissionKey: nil),
        ToolDefinition(id: "trigger.list", name: "List Triggers", category: .productivity, description: "Show your active scheduled agent runs.", icon: "list.bullet.clipboard", tint: "orange", requiresApproval: false, permissionKey: nil),
        ToolDefinition(id: "trigger.cancel", name: "Cancel Trigger", category: .productivity, description: "Cancel a scheduled agent run by name.", icon: "xmark.circle", tint: "red", requiresApproval: true, permissionKey: nil),
        ToolDefinition(id: "alarm.authorization_status", name: "Alarm Auth Status", category: .productivity, description: "Check AlarmKit authorization state.", icon: "checkmark.shield", tint: "orange", requiresApproval: false, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.request_authorization", name: "Request Alarm Auth", category: .productivity, description: "Request permission to use AlarmKit alarms.", icon: "lock.open.display", tint: "orange", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.schedule", name: "Schedule Alarm", category: .productivity, description: "Schedule a prominent alarm at a specific time.", icon: "alarm.waves.left.and.right.fill", tint: "orange", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.countdown", name: "Start Countdown", category: .productivity, description: "Create a countdown alarm by duration.", icon: "timer", tint: "orange", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.list", name: "List Alarms", category: .productivity, description: "List currently active alarms managed by AlarmKit.", icon: "list.bullet", tint: "orange", requiresApproval: false, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.pause", name: "Pause Alarm", category: .productivity, description: "Pause an alarm currently counting down.", icon: "pause.circle", tint: "orange", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.resume", name: "Resume Alarm", category: .productivity, description: "Resume a paused alarm.", icon: "play.circle", tint: "orange", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.stop", name: "Stop Alarm", category: .productivity, description: "Stop an alerting alarm.", icon: "stop.circle", tint: "red", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.snooze", name: "Snooze Alarm", category: .productivity, description: "Snooze an alerting alarm into countdown mode.", icon: "moon.zzz", tint: "orange", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
        ToolDefinition(id: "alarm.cancel", name: "Cancel Alarm", category: .productivity, description: "Cancel a previously scheduled alarm.", icon: "alarm", tint: "red", requiresApproval: true, permissionKey: "NSAlarmKitUsageDescription"),
    ]

    static func find(id: String) -> ToolDefinition? { all.first { $0.id == id } }
}
