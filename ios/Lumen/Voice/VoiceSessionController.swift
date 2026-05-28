import Foundation
import Observation

@MainActor
@Observable
final class VoiceSessionController {
    var state: VoiceSessionState = .idle
    private let recognition = SpeechRecognitionService()
    private let synthesis = SpeechSynthesisService()

    func startPushToTalk() async {
        state = .requestingPermissions
        let ok = await recognition.requestPermissions()
        state = ok ? .listening : .denied("microphone_or_speech_denied")
    }

    func handleAppDidEnterBackground() {
        if VoiceInterruptionHandler.shouldInterruptOnBackground(), state == .listening || state == .speaking {
            state = .interrupted
            synthesis.stop()
        }
    }

    func cancel() {
        synthesis.stop()
        state = .idle
    }
}
