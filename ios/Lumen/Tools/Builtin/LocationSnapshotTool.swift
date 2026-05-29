import Foundation
import CoreLocation

struct LocationSnapshotTool: LocalTool {
    @MainActor protocol Provider { func currentLocation(desiredAccuracy: CLLocationAccuracy, timeout: TimeInterval) async -> CLLocation? }
    @MainActor
    final class CoreLocationProvider: NSObject, Provider, CLLocationManagerDelegate {
        private let manager = CLLocationManager()
        private var active: LocationRequestState?

        override init() {
            super.init()
            manager.delegate = self
        }

        func currentLocation(desiredAccuracy: CLLocationAccuracy, timeout: TimeInterval) async -> CLLocation? {
            guard active == nil else { return nil }
            let state = LocationRequestState()
            active = state
            manager.desiredAccuracy = desiredAccuracy
            manager.requestLocation()
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                state.resume(nil)
                if active === state { active = nil }
            }
            let value = await state.value()
            timeoutTask.cancel()
            if active === state { active = nil }
            return value
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            active?.resume(locations.last)
            active = nil
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            active?.resume(nil)
            active = nil
        }
    }

    private final class LocationRequestState {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CLLocation?, Never>?
        private var completed = false
        private var completedValue: CLLocation?

        func value() async -> CLLocation? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if completed {
                    let value = completedValue
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resume(_ value: CLLocation?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            completedValue = value
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    let definition = SecureToolDefinition(id: "location.snapshot", displayName: "Location Snapshot", description: "Get current location snapshot", category: .permissionRead, requiredPermissions: [.locationWhenInUse], supportsBackgroundExecution: false, requiresUserApproval: false, argumentSchemaDescription: "{desiredAccuracy?:low|medium|high,precision?:approximate|precise}", resultPrivacyLevel: .sensitive, maxOutputCharacters: 600)
    let provider: Provider
    @MainActor init(provider: Provider = CoreLocationProvider()) { self.provider = provider }

    func validateArguments(_ arguments: [String : String]) throws {
        let accuracy = arguments["desiredAccuracy"] ?? "low"; guard ["low","medium","high"].contains(accuracy) else { throw ToolExecutionError.invalidArguments("desiredAccuracy") }
        let precision = arguments["precision"] ?? "approximate"; guard ["approximate","precise"].contains(precision) else { throw ToolExecutionError.invalidArguments("precision") }
    }

    func execute(invocation: ToolInvocation, context: ToolExecutionContext) async -> ToolResult {
        if !context.isForeground { return .init(invocationID: invocation.id, status: .denied, displayText: "Location snapshot is foreground only.", modelText: "Location denied in background.", structuredPayload: nil, privacyLevel: .sensitive, metricsSummary: "bg_denied", errorCode: "bg_denied") }
        do { try validateArguments(invocation.arguments) } catch { return .init(invocationID: invocation.id, status: .failed, displayText: "Invalid location arguments.", modelText: "Location input invalid.", structuredPayload: nil, privacyLevel: .sensitive, metricsSummary: "invalid_args", errorCode: "invalid") }
        let st = await context.permissionRegistry.currentStatus(for: .locationWhenInUse)
        let gate = PermissionGate.evaluate(domain: .locationWhenInUse, state: st, isForeground: context.isForeground)
        guard gate.allowed else { return .init(invocationID: invocation.id, status: .denied, displayText: gate.reason ?? "Location permission required.", modelText: "Location permission required.", structuredPayload: nil, privacyLevel: .sensitive, metricsSummary: "permission_denied", errorCode: "permission") }
        let desired = invocation.arguments["desiredAccuracy"] ?? "low"
        let precision = invocation.arguments["precision"] ?? "approximate"
        let clAcc: CLLocationAccuracy = desired == "high" ? kCLLocationAccuracyBest : (desired == "medium" ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyKilometer)
        guard let loc = await provider.currentLocation(desiredAccuracy: clAcc, timeout: 6) else { return .init(invocationID: invocation.id, status: .unavailable, displayText: "Location not available right now.", modelText: "Location unavailable.", structuredPayload: nil, privacyLevel: .sensitive, metricsSummary: "timeout", errorCode: "timeout") }
        let lat = precision == "precise" && invocation.source == .userInitiated ? loc.coordinate.latitude : (loc.coordinate.latitude*100).rounded()/100
        let lon = precision == "precise" && invocation.source == .userInitiated ? loc.coordinate.longitude : (loc.coordinate.longitude*100).rounded()/100
        let text = "lat=\(lat), lon=\(lon), hAcc=\(Int(loc.horizontalAccuracy))m"
        return .init(invocationID: invocation.id, status: .success, displayText: text, modelText: text, structuredPayload: ["timestamp": ISO8601DateFormatter().string(from: loc.timestamp), "authorization": st.rawValue], privacyLevel: .sensitive, metricsSummary: precision == "precise" ? "precise" : "approximate", errorCode: nil)
    }
}
