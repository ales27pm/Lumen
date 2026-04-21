import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications
import EventKit
import UIKit

@MainActor
final class TriggerScheduler {
    static let shared = TriggerScheduler()

    static let refreshIdentifier = "com.27pm.lumen.agent.refresh"
    static let processIdentifier = "com.27pm.lumen.agent.process"
    static let notificationCategory = "LumenAgent"

    private var registered = false
    private var isRunning = false
    var lastPermissionGranted: Bool?

    func registerTasks() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await self.handleRefresh(task: refresh) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processIdentifier, using: nil) { task in
            guard let proc = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await self.handleRefresh(task: proc) }
        }
        let center = UNUserNotificationCenter.current()
        let category = UNNotificationCategory(identifier: Self.notificationCategory, actions: [], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        lastPermissionGranted = granted
        return granted
    }

    func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        req.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(req)

        let proc = BGProcessingTaskRequest(identifier: Self.processIdentifier)
        proc.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        proc.requiresNetworkConnectivity = true
        proc.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(proc)
    }

    private func handleRefresh(task: BGTask) async {
        scheduleBackgroundRefresh()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        guard let container = SharedContainer.shared else { task.setTaskCompleted(success: true); return }
        let context = ModelContext(container)
        let appState = AppState()
        await fireDueTriggers(context: context, appState: appState)
        task.setTaskCompleted(success: true)
    }

    // MARK: - Firing

    func fireDueTriggers(context: ModelContext, appState: AppState) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let now = Date()
        guard let all = try? context.fetch(FetchDescriptor<Trigger>()) else { return }
        for t in all where !t.isPaused {
            if let next = t.nextFireAt ?? t.computeNextFire(from: now), next <= now.addingTimeInterval(30) {
                await runTrigger(t, context: context, appState: appState, notify: true)
            } else if t.nextFireAt == nil {
                t.nextFireAt = t.computeNextFire(from: now)
            }
        }
        try? context.save()
    }

    @discardableResult
    func runTrigger(_ trigger: Trigger, context: ModelContext, appState: AppState, notify: Bool) async -> String {
        let result = await AgentRunner.runHeadless(prompt: trigger.prompt, appState: appState, context: context, maxSteps: min(appState.maxAgentSteps, 3))
        trigger.lastRunAt = Date()
        trigger.lastResult = result.text
        switch trigger.kind {
        case .once:
            trigger.isPaused = true
            trigger.nextFireAt = nil
        default:
            trigger.nextFireAt = trigger.computeNextFire(from: Date())
        }
        try? context.save()

        if notify {
            await postNotification(trigger: trigger, body: result.text)
        }
        return result.text
    }

    private func postNotification(trigger: Trigger, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = trigger.title.isEmpty ? "Lumen" : trigger.title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["triggerID": trigger.id.uuidString]
        let req = UNNotificationRequest(identifier: trigger.id.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Local scheduling (user-facing, best-effort while app is alive or via background refresh)

    func refreshNextFireTimes(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<Trigger>()) else { return }
        let now = Date()
        for t in all {
            t.nextFireAt = t.isPaused ? nil : t.computeNextFire(from: now)
        }
        try? context.save()
    }

    // MARK: - Calendar helpers

    func minutesUntilNextEvent() async -> Int? {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else { return nil }
        let now = Date()
        let end = now.addingTimeInterval(24 * 3600)
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: pred).filter { $0.startDate > now }.sorted { $0.startDate < $1.startDate }
        guard let next = events.first else { return nil }
        return Int(next.startDate.timeIntervalSince(now) / 60)
    }
}
