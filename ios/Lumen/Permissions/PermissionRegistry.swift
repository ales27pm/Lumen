import Foundation
import AVFoundation
import Speech
import Photos
import CoreLocation
import EventKit
import Contacts
import UserNotifications
import CoreMotion

@MainActor
final class PermissionRegistry: NSObject, CLLocationManagerDelegate {
    static let shared = PermissionRegistry()
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<PermissionRequestResult, Never>?
    private var networkAccessEnabled = false

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func setNetworkAccessEnabled(_ enabled: Bool) { networkAccessEnabled = enabled }

    func currentStatus(for domain: PermissionDomain) async -> PermissionState {
        switch domain {
        case .microphone:
            switch AVAudioSession.sharedInstance().recordPermission { case .granted: return .granted; case .denied: return .denied; case .undetermined: return .notDetermined @unknown default: return .unknown }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() { case .authorized: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) { case .authorized: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown }
        case .photoLibrary:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) { case .authorized, .limited: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown }
        case .locationWhenInUse:
            switch locationManager.authorizationStatus { case .authorizedWhenInUse, .authorizedAlways: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown }
        case .calendars:
            let status = EKEventStore.authorizationStatus(for: .event); return mapEventKit(status)
        case .reminders:
            let status = EKEventStore.authorizationStatus(for: .reminder); return mapEventKit(status)
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) { case .authorized: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown }
        case .notifications:
            let s = await UNUserNotificationCenter.current().notificationSettings(); switch s.authorizationStatus { case .authorized, .provisional, .ephemeral: return .granted; case .denied: return .denied; case .notDetermined: return .notDetermined @unknown default: return .unknown }
        case .localNetwork:
            return Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") == nil ? .unavailable : .unknown
        case .motion:
            return CMMotionActivityManager.isActivityAvailable() ? .unknown : .unavailable
        case .appIntents, .filesUserSelected:
            return .granted
        case .networkAccess:
            return networkAccessEnabled ? .granted : .denied
        }
    }

    func request(_ domain: PermissionDomain) async -> PermissionRequestResult {
        switch domain {
        case .microphone:
            let granted = await AVAudioSession.sharedInstance().requestRecordPermission()
            return .init(domain: domain, state: granted ? .granted : .denied, message: granted ? "Granted" : "Denied")
        case .speechRecognition:
            let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            return .init(domain: domain, state: mapSpeech(status), message: "Speech authorization updated")
        case .camera:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return .init(domain: domain, state: granted ? .granted : .denied, message: granted ? "Granted" : "Denied")
        case .photoLibrary:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return .init(domain: domain, state: mapPhoto(status), message: "Photo authorization updated")
        case .locationWhenInUse:
            locationManager.requestWhenInUseAuthorization()
            return await withCheckedContinuation { cont in self.locationContinuation = cont }
        case .calendars:
            let store = EKEventStore(); let granted = (try? await store.requestFullAccessToEvents()) ?? false
            return .init(domain: domain, state: granted ? .granted : .denied, message: granted ? "Granted" : "Denied")
        case .reminders:
            let store = EKEventStore(); let granted = (try? await store.requestFullAccessToReminders()) ?? false
            return .init(domain: domain, state: granted ? .granted : .denied, message: granted ? "Granted" : "Denied")
        case .contacts:
            let store = CNContactStore(); let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            return .init(domain: domain, state: granted ? .granted : .denied, message: granted ? "Granted" : "Denied")
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.sound,.badge])) ?? false
            return .init(domain: domain, state: granted ? .granted : .denied, message: granted ? "Granted" : "Denied")
        case .networkAccess:
            return .init(domain: domain, state: await currentStatus(for: domain), message: "Controlled by in-app setting")
        default:
            return .init(domain: domain, state: await currentStatus(for: domain), message: "No runtime prompt")
        }
    }

    func userFacingReason(for domain: PermissionDomain) -> String { "Lumen uses \(domain.rawValue) only for explicit tool requests." }
    func requiredInfoPlistKeys(for domain: PermissionDomain) -> [String] { switch domain { case .microphone: return ["NSMicrophoneUsageDescription"]; case .speechRecognition: return ["NSSpeechRecognitionUsageDescription"]; case .camera: return ["NSCameraUsageDescription"]; case .photoLibrary: return ["NSPhotoLibraryUsageDescription"]; case .locationWhenInUse: return ["NSLocationWhenInUseUsageDescription"]; case .calendars: return ["NSCalendarsUsageDescription"]; case .reminders: return ["NSRemindersUsageDescription"]; case .contacts: return ["NSContactsUsageDescription"]; case .localNetwork: return ["NSLocalNetworkUsageDescription"]; default: return [] } }
    func diagnostics() async -> [PermissionDomain: PermissionState] { var out:[PermissionDomain:PermissionState]=[:]; for d in PermissionDomain.allCases { out[d] = await currentStatus(for: d) }; return out }

    private func mapEventKit(_ s: EKAuthorizationStatus) -> PermissionState { switch s { case .fullAccess, .writeOnly: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown } }
    private func mapSpeech(_ s: SFSpeechRecognizerAuthorizationStatus) -> PermissionState { switch s { case .authorized: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown } }
    private func mapPhoto(_ s: PHAuthorizationStatus) -> PermissionState { switch s { case .authorized, .limited: return .granted; case .denied: return .denied; case .restricted: return .restricted; case .notDetermined: return .notDetermined @unknown default: return .unknown } }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { guard let c = locationContinuation else { return }; locationContinuation=nil; Task { let state = await currentStatus(for: .locationWhenInUse); c.resume(returning: .init(domain: .locationWhenInUse, state: state, message: "Location authorization updated")) } }
}
