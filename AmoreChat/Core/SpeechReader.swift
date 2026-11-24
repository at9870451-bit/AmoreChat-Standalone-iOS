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
        // Dictation leaves AVAudioSession in its record category. Restore output
        // before manual read-aloud so the speaker still works after dictation.
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio) }
        catch { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
