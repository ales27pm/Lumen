import Foundation
import CoreLocation

/// One-shot location fetch with a per-call delegate — no shared singleton state.
@MainActor
enum LocationProbe {
    static func currentCoordinate(timeout: TimeInterval = 8) async -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .denied || status == .restricted {
            return nil
        }

        let holder = DelegateHolder()
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            let delegate = SingleShotLocationDelegate { coord in
                cont.resume(returning: coord)
            }
            holder.delegate = delegate
            manager.delegate = delegate

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                delegate.finish(with: nil)
            }

            manager.requestLocation()
            _ = holder
        }
    }

    static func currentDescription(timeout: TimeInterval = 8) async -> String {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .denied || status == .restricted {
            return "Location access was denied."
        }

        let holder = DelegateHolder()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let delegate = SingleShotDescriptionDelegate { text in
                cont.resume(returning: text)
            }
            holder.delegate = delegate
            manager.delegate = delegate

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                delegate.finish(with: "Couldn't get location (timed out).")
            }

            manager.requestLocation()
            _ = holder
        }
    }
}

@MainActor
private final class DelegateHolder {
    var delegate: AnyObject?
}

nonisolated final class SingleShotLocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let handler: (CLLocationCoordinate2D?) -> Void
    private var done = false
    private let lock = NSLock()

    init(handler: @escaping (CLLocationCoordinate2D?) -> Void) { self.handler = handler }

    func finish(with coord: CLLocationCoordinate2D?) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        handler(coord)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
}

nonisolated final class SingleShotDescriptionDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let handler: (String) -> Void
    private var done = false
    private let lock = NSLock()

    init(handler: @escaping (String) -> Void) { self.handler = handler }

    func finish(with text: String) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        handler(text)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            finish(with: "Couldn't get location.")
            return
        }
        let c = loc.coordinate
        finish(with: String(format: "Current location: %.4f, %.4f (±%.0fm)", c.latitude, c.longitude, loc.horizontalAccuracy))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: "Couldn't get location: \(error.localizedDescription)")
    }
}
