import Foundation
import CoreLocation

/// One-shot location fetch with a per-call delegate — no shared singleton state.
@MainActor
enum LocationProbe {
    static func currentCoordinate(timeout: TimeInterval = 8) async -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return nil
        }

        let holder = DelegateHolder()
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            let delegate = SingleShotLocationDelegate(manager: manager) { coord in
                cont.resume(returning: coord)
            }
            holder.delegate = delegate
            manager.delegate = delegate

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                delegate.finish(with: nil)
            }

            delegate.begin()
            _ = holder
        }
    }

    static func currentDescription(timeout: TimeInterval = 8) async -> String {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return "Location access was denied."
        }

        let holder = DelegateHolder()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let delegate = SingleShotDescriptionDelegate(manager: manager) { text in
                cont.resume(returning: text)
            }
            holder.delegate = delegate
            manager.delegate = delegate

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                delegate.finish(with: "Couldn't get location (timed out).")
            }

            delegate.begin()
            _ = holder
        }
    }
}

@MainActor
private final class DelegateHolder {
    var delegate: AnyObject?
}

@MainActor
final class SingleShotLocationDelegate: NSObject, CLLocationManagerDelegate {
    /// Concurrency contract: callbacks are normalized onto MainActor before reading or mutating state.
    private let manager: CLLocationManager
    private let handler: (CLLocationCoordinate2D?) -> Void
    private var done = false

    init(manager: CLLocationManager, handler: @escaping (CLLocationCoordinate2D?) -> Void) {
        self.manager = manager
        self.handler = handler
    }

    func begin() {
        MainActor.preconditionIsolated()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(with: nil)
        @unknown default:
            finish(with: nil)
        }
    }

    func finish(with coord: CLLocationCoordinate2D?) {
        MainActor.preconditionIsolated()
        if done { return }
        done = true
        handler(coord)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        Task { @MainActor in
            self.finish(with: coord)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard !self.done else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                self.finish(with: nil)
            case .notDetermined:
                break
            @unknown default:
                self.finish(with: nil)
            }
        }
    }
}

@MainActor
final class SingleShotDescriptionDelegate: NSObject, CLLocationManagerDelegate {
    /// Concurrency contract: callbacks are normalized onto MainActor before reading or mutating state.
    private let manager: CLLocationManager
    private let handler: (String) -> Void
    private var done = false

    init(manager: CLLocationManager, handler: @escaping (String) -> Void) {
        self.manager = manager
        self.handler = handler
    }

    func begin() {
        MainActor.preconditionIsolated()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(with: "Location access was denied.")
        @unknown default:
            finish(with: "Couldn't determine location authorization state.")
        }
    }

    func finish(with text: String) {
        MainActor.preconditionIsolated()
        if done { return }
        done = true
        handler(text)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let message: String
        if let loc = locations.last {
            let c = loc.coordinate
            message = String(format: "Current location: %.4f, %.4f (±%.0fm)", c.latitude, c.longitude, loc.horizontalAccuracy)
        } else {
            message = "Couldn't get location."
        }

        Task { @MainActor in
            self.finish(with: message)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: "Couldn't get location: \(error.localizedDescription)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard !self.done else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                self.finish(with: "Location access was denied.")
            case .notDetermined:
                break
            @unknown default:
                self.finish(with: "Couldn't determine location authorization state.")
            }
        }
    }
}
