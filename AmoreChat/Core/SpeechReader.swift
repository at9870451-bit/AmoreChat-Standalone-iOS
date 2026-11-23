import AVFoundation
import Foundation
import Observation

/// Native read-aloud playback; never synthesizes a model response.
@MainActor @Observable final class SpeechReader {
    private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking: Bool { synthesizer.isSpeaking }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
    func read(_ text: String, voiceID: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
