import Foundation
import EventKit
import Contacts
import CoreLocation
import MapKit
import MessageUI
import UIKit
import Photos
import HealthKit
import CoreMotion
import AVFoundation
import SwiftData
import PDFKit

@MainActor
final class ToolExecutor {
    static let shared = ToolExecutor()

    @ObservationIgnored private let locationManager = CLLocationManager()

    func execute(_ toolID: String, arguments: [String: String]) async -> String {
        switch toolID {
        case "calendar.create":
            return await createEvent(title: arguments["title"] ?? "New Event", startsInMinutes: Int(arguments["startsInMinutes"] ?? "60") ?? 60)
        case "calendar.list":
            return await listEvents()
        case "reminders.create":
            return await createReminder(title: arguments["title"] ?? "Reminder")
        case "reminders.list":
            return await listReminders()
        case "contacts.search":
            return await searchContacts(query: arguments["query"] ?? "")
        case "location.current":
            return await currentLocation()
        case "maps.directions":
            return openMaps(destination: arguments["destination"] ?? "")
        case "messages.draft":
            return "Drafted iMessage: \"\(arguments["body"] ?? "")\" (opens Messages.app on a real device)."
        case "mail.draft":
            return "Drafted email: \"\(arguments["body"] ?? "")\" (opens Mail.app on a real device)."
        case "phone.call":
            if let number = arguments["number"], let url = URL(string: "tel://\(number)") {
                await UIApplication.shared.open(url)
                return "Calling \(number)…"
            }
            return "No phone number provided."
        case "photos.search":
            return await searchPhotos(query: arguments["query"] ?? "")
        case "camera.capture":
            return await captureImage()
        case "health.summary":
            return await healthSummary()
        case "motion.activity":
            return await motionActivity()
        case "maps.search":
            return await searchNearby(query: arguments["query"] ?? "")
        case "web.search":
            return await webSearch(query: arguments["query"] ?? "")
        case "web.fetch":
            return await webFetch(url: arguments["url"] ?? "")
        case "files.read":
            return await readImportedFile(name: arguments["name"] ?? "")
        case "memory.save":
            return await saveMemoryTool(content: arguments["content"] ?? "", kind: arguments["kind"] ?? "fact")
        case "memory.recall":
            return await recallMemoryTool(query: arguments["query"] ?? "")
        case "rag.search":
            return await ragSearch(query: arguments["query"] ?? "", limit: Int(arguments["limit"] ?? "5") ?? 5)
        case "rag.index_files":
            return await ragIndexFiles()
        case "rag.index_photos":
            return await ragIndexPhotos(months: Int(arguments["months"] ?? "6") ?? 6)
        case "trigger.create":
            return await triggerCreate(args: arguments)
        case "trigger.list":
            return await triggerList()
        case "trigger.cancel":
            return await triggerCancel(title: arguments["title"] ?? arguments["id"] ?? "")
        default:
            return "Unknown tool: \(toolID)"
        }
    }

    private func createEvent(title: String, startsInMinutes: Int) async -> String {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { return "Calendar access was denied." }
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = Date().addingTimeInterval(TimeInterval(startsInMinutes * 60))
            event.endDate = event.startDate.addingTimeInterval(3600)
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return "Created event \"\(title)\" starting \(event.startDate.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            return "Couldn't create event: \(error.localizedDescription)"
        }
    }

    private func listEvents() async -> String {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { return "Calendar access was denied." }
            let predicate = store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(86400 * 7), calendars: nil)
            let events = store.events(matching: predicate).prefix(5)
            if events.isEmpty { return "No events in the next 7 days." }
            return events.map { "• \($0.title ?? "Untitled") — \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n")
        } catch {
            return "Couldn't load events: \(error.localizedDescription)"
        }
    }

    private func createReminder(title: String) async -> String {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { return "Reminders access was denied." }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            return "Added reminder: \"\(title)\"."
        } catch {
            return "Couldn't add reminder: \(error.localizedDescription)"
        }
    }

    private func listReminders() async -> String {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { return "Reminders access was denied." }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            return await withCheckedContinuation { cont in
                store.fetchReminders(matching: predicate) { reminders in
                    let items = (reminders ?? []).prefix(5)
                    if items.isEmpty { cont.resume(returning: "No pending reminders.") }
                    else { cont.resume(returning: items.map { "• \($0.title ?? "Untitled")" }.joined(separator: "\n")) }
                }
            }
        } catch {
            return "Couldn't load reminders: \(error.localizedDescription)"
        }
    }

    private func searchContacts(query: String) async -> String {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else { return "Contacts access was denied." }
            let predicate = CNContact.predicateForContacts(matchingName: query)
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
            let results = try store.unifiedContacts(matching: predicate, keysToFetch: keys).prefix(5)
            if results.isEmpty { return "No contacts match \"\(query)\"." }
            return results.map { c in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let phone = c.phoneNumbers.first?.value.stringValue ?? "no phone"
                return "• \(name) — \(phone)"
            }.joined(separator: "\n")
        } catch {
            return "Couldn't search contacts: \(error.localizedDescription)"
        }
    }

    private func currentLocation() async -> String {
        locationManager.requestWhenInUseAuthorization()
        return await withCheckedContinuation { cont in
            let delegate = LocationDelegate { result in
                cont.resume(returning: result)
            }
            LocationHolder.shared.delegate = delegate
            locationManager.delegate = delegate
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.requestLocation()
        }
    }

    // MARK: - Photos

    private func searchPhotos(query: String) async -> String {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            return "Photo library access was denied."
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        let cal = Calendar.current

        var dateRange: (Date, Date)? = nil
        if trimmed.contains("today") {
            let start = cal.startOfDay(for: now)
            dateRange = (start, now)
        } else if trimmed.contains("yesterday") {
            let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now)!)
            let end = cal.startOfDay(for: now)
            dateRange = (start, end)
        } else if trimmed.contains("week") {
            dateRange = (cal.date(byAdding: .day, value: -7, to: now)!, now)
        } else if trimmed.contains("month") {
            dateRange = (cal.date(byAdding: .month, value: -1, to: now)!, now)
        } else if trimmed.contains("year") {
            dateRange = (cal.date(byAdding: .year, value: -1, to: now)!, now)
        }

        var matches: [PHAsset] = []
        let wantFavorites = trimmed.contains("favorite") || trimmed.contains("favourite")
        let wantSelfies = trimmed.contains("selfie")
        let wantVideos = trimmed.contains("video")
        let wantScreenshots = trimmed.contains("screenshot")

        assets.enumerateObjects { asset, _, _ in
            if let range = dateRange, let created = asset.creationDate {
                if created < range.0 || created > range.1 { return }
            }
            if wantFavorites && !asset.isFavorite { return }
            if wantSelfies && asset.mediaSubtypes.contains(.photoScreenshot) { return }
            if wantScreenshots && !asset.mediaSubtypes.contains(.photoScreenshot) { return }
            if wantVideos && asset.mediaType != .video { return }
            matches.append(asset)
        }

        let total = matches.count
        let totalInLibrary = assets.count
        if trimmed.isEmpty {
            return "Photo library has \(totalInLibrary) images. Most recent: \(formatAssetDate(assets.firstObject?.creationDate))."
        }
        if total == 0 {
            return "No photos match \"\(query)\"."
        }
        let sample = matches.prefix(5).map { formatAssetDate($0.creationDate) }.joined(separator: ", ")
        return "Found \(total) photos matching \"\(query)\". Recent dates: \(sample)."
    }

    private func formatAssetDate(_ date: Date?) -> String {
        guard let date else { return "unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Camera

    private func captureImage() async -> String {
        #if targetEnvironment(simulator)
        return "Camera is unavailable in the simulator. Install on a real device to capture images."
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        guard granted else { return "Camera access was denied." }
        guard AVCaptureDevice.default(for: .video) != nil else {
            return "No camera device available."
        }
        return await CameraCaptureController.shared.capture()
        #endif
    }

    // MARK: - Health

    private let healthStore = HKHealthStore()

    private func healthSummary() async -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "Health data isn't available on this device."
        }
        let stepType = HKQuantityType(.stepCount)
        let hrType = HKQuantityType(.heartRate)
        let sleepType = HKCategoryType(.sleepAnalysis)
        let energyType = HKQuantityType(.activeEnergyBurned)
        let distanceType = HKQuantityType(.distanceWalkingRunning)

        let readTypes: Set<HKObjectType> = [stepType, hrType, sleepType, energyType, distanceType]

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            return "Couldn't request Health access: \(error.localizedDescription)"
        }

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = Date()

        async let steps = sumQuantity(type: stepType, unit: .count(), start: start, end: end)
        async let distance = sumQuantity(type: distanceType, unit: .meter(), start: start, end: end)
        async let energy = sumQuantity(type: energyType, unit: .kilocalorie(), start: start, end: end)
        async let hr = averageQuantity(type: hrType, unit: HKUnit.count().unitDivided(by: .minute()), start: cal.date(byAdding: .hour, value: -24, to: end)!, end: end)
        async let sleep = sleepHours(start: cal.date(byAdding: .hour, value: -36, to: end)!, end: end)

        let (s, d, e, h, sl) = await (steps, distance, energy, hr, sleep)

        var parts: [String] = []
        if let s { parts.append("\(Int(s).formatted()) steps") }
        if let d { parts.append(String(format: "%.2f km", d / 1000)) }
        if let e { parts.append("\(Int(e)) kcal") }
        if let h { parts.append(String(format: "%.0f bpm avg HR", h)) }
        if let sl { parts.append(String(format: "%.1fh sleep", sl)) }

        if parts.isEmpty {
            return "No Health data available yet today (or access denied). Open the Health app and grant permission."
        }
        return "Today's Health: " + parts.joined(separator: " · ")
    }

    private func sumQuantity(type: HKQuantityType, unit: HKUnit, start: Date, end: Date) async -> Double? {
        await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            healthStore.execute(q)
        }
    }

    private func averageQuantity(type: HKQuantityType, unit: HKUnit, start: Date, end: Date) async -> Double? {
        await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
                cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            healthStore.execute(q)
        }
    }

    private func sleepHours(start: Date, end: Date) async -> Double? {
        await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    cont.resume(returning: nil); return
                }
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                ]
                let total = samples
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                cont.resume(returning: total > 0 ? total / 3600 : nil)
            }
            healthStore.execute(q)
        }
    }

    // MARK: - Motion

    @ObservationIgnored private let pedometer = CMPedometer()
    @ObservationIgnored private let activityManager = CMMotionActivityManager()

    private func motionActivity() async -> String {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return "Motion activity isn't available on this device."
        }

        let end = Date()
        let start = Calendar.current.startOfDay(for: end)

        async let ped = pedometerData(start: start, end: end)
        async let activities = activitySegments(start: start, end: end)

        let (p, acts) = await (ped, activities)

        var parts: [String] = []
        if let p {
            parts.append("\(p.steps) steps")
            if let dist = p.distance { parts.append(String(format: "%.2f km", dist / 1000)) }
            if let floors = p.floors { parts.append("\(floors) floors") }
        }
        if !acts.isEmpty {
            let summary = acts.map { "\($0.minutes)m \($0.label)" }.joined(separator: ", ")
            parts.append("activity: \(summary)")
        }

        if parts.isEmpty {
            return "No motion data today. Grant Motion permission and carry the device."
        }
        return "Today's motion — " + parts.joined(separator: " · ")
    }

    private func pedometerData(start: Date, end: Date) async -> (steps: Int, distance: Double?, floors: Int?)? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return await withCheckedContinuation { cont in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                guard let data else { cont.resume(returning: nil); return }
                cont.resume(returning: (data.numberOfSteps.intValue, data.distance?.doubleValue, data.floorsAscended?.intValue))
            }
        }
    }

    private func activitySegments(start: Date, end: Date) async -> [(label: String, minutes: Int)] {
        let status = CMMotionActivityManager.authorizationStatus()
        if status == .denied || status == .restricted { return [] }
        return await withCheckedContinuation { cont in
            activityManager.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                guard let activities else { cont.resume(returning: []); return }
                var totals: [String: TimeInterval] = [:]
                for i in 0..<activities.count {
                    let a = activities[i]
                    let next = i + 1 < activities.count ? activities[i + 1].startDate : end
                    let duration = next.timeIntervalSince(a.startDate)
                    guard duration > 0 else { continue }
                    let label: String
                    if a.walking { label = "walking" }
                    else if a.running { label = "running" }
                    else if a.cycling { label = "cycling" }
                    else if a.automotive { label = "driving" }
                    else if a.stationary { label = "stationary" }
                    else { continue }
                    totals[label, default: 0] += duration
                }
                let sorted = totals
                    .map { (label: $0.key, minutes: Int($0.value / 60)) }
                    .filter { $0.minutes > 0 }
                    .sorted { $0.minutes > $1.minutes }
                cont.resume(returning: sorted)
            }
        }
    }

    private func searchNearby(query: String) async -> String {
        guard !query.isEmpty else { return "Need a search query (e.g. 'coffee')." }
        locationManager.requestWhenInUseAuthorization()
        let coord: CLLocationCoordinate2D? = await withCheckedContinuation { cont in
            let delegate = LocationCoordDelegate { c in cont.resume(returning: c) }
            LocationHolder.shared.coordDelegate = delegate
            locationManager.delegate = delegate
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.requestLocation()
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coord {
            request.region = MKCoordinateRegion(center: coord, latitudinalMeters: 3000, longitudinalMeters: 3000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            let items = response.mapItems.prefix(5)
            if items.isEmpty { return "No places found for \"\(query)\"." }
            return items.map { item in
                let name = item.name ?? "Place"
                let addr = [item.placemark.thoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: ", ")
                return "\u{2022} \(name) \u{2014} \(addr.isEmpty ? "nearby" : addr)"
            }.joined(separator: "\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    private func webSearch(query: String) async -> String {
        guard !query.isEmpty else { return "Need a query." }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://duckduckgo.com/?q=\(q)&format=json&no_redirect=1&no_html=1") else {
            return "Invalid query."
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "No results."
            }
            var lines: [String] = []
            if let abstract = obj["AbstractText"] as? String, !abstract.isEmpty {
                lines.append(abstract)
                if let src = obj["AbstractURL"] as? String, !src.isEmpty { lines.append(src) }
            }
            if let related = obj["RelatedTopics"] as? [[String: Any]] {
                for item in related.prefix(5) {
                    if let text = item["Text"] as? String, !text.isEmpty {
                        lines.append("\u{2022} \(text)")
                    }
                }
            }
            if lines.isEmpty {
                return "No direct answer. Try a different phrasing, or use web.fetch with a URL."
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    private func webFetch(url: String) async -> String {
        guard let u = URL(string: url) else { return "Invalid URL." }
        do {
            var req = URLRequest(url: u)
            req.setValue("Mozilla/5.0 (iPhone; Lumen/2.0)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { return "Couldn't decode page." }
            let text = stripHTML(html)
            let trimmed = String(text.prefix(2000))
            return trimmed.isEmpty ? "Page was empty." : trimmed
        } catch {
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    private func stripHTML(_ html: String) -> String {
        var s = html
        if let range = s.range(of: "<body", options: .caseInsensitive) {
            s = String(s[range.lowerBound...])
        }
        let patterns = ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readImportedFile(name: String) async -> String {
        let dir = FileStore.importsDirectory
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if trimmed.isEmpty {
            if files.isEmpty { return "No imported files. Tap the paperclip to add one." }
            return "Imported files:\n" + files.map { "\u{2022} \($0)" }.joined(separator: "\n")
        }
        guard let match = files.first(where: { $0.localizedCaseInsensitiveContains(trimmed) }) else {
            return "File not found. Available: \(files.joined(separator: ", "))"
        }
        let url = dir.appendingPathComponent(match)
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { return "Couldn't open PDF." }
            var text = ""
            for i in 0..<min(pdf.pageCount, 20) {
                text += pdf.page(at: i)?.string ?? ""
                text += "\n"
            }
            return String(text.prefix(3000))
        }
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else {
            return "Couldn't read \(match)."
        }
        return String(s.prefix(3000))
    }

    private func saveMemoryTool(content: String, kind: String) async -> String {
        guard !content.isEmpty else { return "Need content." }
        let k = MemoryKind(rawValue: kind) ?? .fact
        guard let container = await SharedContainer.shared else { return "Memory unavailable." }
        let ctx = ModelContext(container)
        await MemoryStore.remember(content, kind: k, source: "agent", context: ctx)
        return "Saved: \(content)"
    }

    private func recallMemoryTool(query: String) async -> String {
        guard let container = await SharedContainer.shared else { return "Memory unavailable." }
        let ctx = ModelContext(container)
        let items = await MemoryStore.recall(query: query, context: ctx, limit: 5)
        if items.isEmpty { return "No matching memories." }
        return items.map { "\u{2022} \($0.content)" }.joined(separator: "\n")
    }

    // MARK: - RAG

    private func ragSearch(query: String, limit: Int) async -> String {
        guard !query.isEmpty else { return "Need a search query." }
        guard let container = SharedContainer.shared else { return "RAG store unavailable." }
        let ctx = ModelContext(container)
        let results = await RAGStore.search(query: query, context: ctx, limit: limit)
        if results.isEmpty { return "No matches. Try reindexing files or photos first." }
        return results.enumerated().map { idx, r in
            let src = "\(r.chunk.kind.label) · \(r.chunk.sourceName)"
            let snippet = r.chunk.content.prefix(300)
            return "[\(idx + 1)] \(src)\n\(snippet)"
        }.joined(separator: "\n\n")
    }

    private func ragIndexFiles() async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let n = await RAGStore.indexImportedFiles(context: ctx)
        return "Indexed \(n) chunks from imported files."
    }

    private func ragIndexPhotos(months: Int) async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let n = await RAGStore.indexPhotos(monthsBack: max(1, months), context: ctx)
        if n == 0 { return "Couldn't index photos (permission denied or empty library)." }
        return "Indexed \(n) monthly photo summaries."
    }

    // MARK: - Triggers

    private func triggerCreate(args: [String: String]) async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let title = args["title"] ?? "Scheduled run"
        let prompt = args["prompt"] ?? title
        let schedule = TriggerScheduleType(rawValue: args["schedule"] ?? "once") ?? .once
        let trigger: Trigger
        switch schedule {
        case .once:
            let minutes = Int(args["inMinutes"] ?? "60") ?? 60
            let fire = Date().addingTimeInterval(TimeInterval(minutes * 60))
            trigger = Trigger(title: title, prompt: prompt, scheduleType: .once, fireDate: fire)
        case .daily:
            let hhmm = args["atTime"] ?? "09:00"
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            let mins = (parts.first ?? 9) * 60 + (parts.count > 1 ? parts[1] : 0)
            trigger = Trigger(title: title, prompt: prompt, scheduleType: .daily, timeOfDayMinutes: mins)
        case .interval:
            let seconds = TimeInterval(Int(args["intervalSeconds"] ?? "3600") ?? 3600)
            trigger = Trigger(title: title, prompt: prompt, scheduleType: .interval, intervalSeconds: seconds)
        case .beforeNextEvent:
            let before = Int(args["beforeMinutes"] ?? "15") ?? 15
            trigger = Trigger(title: title, prompt: prompt, scheduleType: .beforeNextEvent, beforeNextEventMinutes: before)
        }
        trigger.nextFireAt = trigger.computeNextFire()
        ctx.insert(trigger)
        try? ctx.save()
        await TriggerScheduler.shared.requestPermission()
        TriggerScheduler.shared.scheduleBackgroundRefresh()
        let when = trigger.nextFireAt?.formatted(date: .abbreviated, time: .shortened) ?? "background"
        return "Scheduled \"\(title)\" (\(schedule.label)) — next run: \(when)."
    }

    private func triggerList() async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Trigger>())) ?? []
        if all.isEmpty { return "No scheduled runs." }
        return all.map { t in
            let next = t.nextFireAt?.formatted(date: .abbreviated, time: .shortened) ?? (t.isPaused ? "paused" : "—")
            return "• \(t.title) — \(t.kind.label) — next: \(next)"
        }.joined(separator: "\n")
    }

    private func triggerCancel(title: String) async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let all = (try? ctx.fetch(FetchDescriptor<Trigger>())) ?? []
        let match = all.first { $0.title.localizedCaseInsensitiveContains(title) || $0.id.uuidString == title }
        guard let m = match else { return "No trigger matching \"\(title)\"." }
        ctx.delete(m)
        try? ctx.save()
        return "Cancelled \"\(m.title)\"."
    }

    private func openMaps(destination: String) -> String {
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?daddr=\(encoded)") {
            Task { await UIApplication.shared.open(url) }
            return "Opening Maps with directions to \(destination)."
        }
        return "Couldn't build maps URL."
    }
}

nonisolated final class LocationHolder: @unchecked Sendable {
    static let shared = LocationHolder()
    var delegate: LocationDelegate?
    var coordDelegate: LocationCoordDelegate?
}

nonisolated final class LocationCoordDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let handler: (CLLocationCoordinate2D?) -> Void
    private var done = false
    init(handler: @escaping (CLLocationCoordinate2D?) -> Void) { self.handler = handler }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !done, let loc = locations.last else { return }
        done = true
        handler(loc.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard !done else { return }
        done = true
        handler(nil)
    }
}

nonisolated final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let handler: (String) -> Void
    private var done = false
    init(handler: @escaping (String) -> Void) { self.handler = handler }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !done, let loc = locations.last else { return }
        done = true
        let coord = loc.coordinate
        handler(String(format: "Current location: %.4f, %.4f (±%.0fm)", coord.latitude, coord.longitude, loc.horizontalAccuracy))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard !done else { return }
        done = true
        handler("Couldn't get location: \(error.localizedDescription)")
    }
}
