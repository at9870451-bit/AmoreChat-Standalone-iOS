import AVFoundation
import Foundation
import Observation
import Speech

@MainActor @Observable final class SpeechInput {
    var isRecording = false
    var errorText: String?
    var transcript = ""
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?

    func toggle() async {
        if isRecording { stop(); return }
        let authorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else { errorText = "请在系统设置中允许语音识别。"; return }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else { errorText = "请在系统设置中允许麦克风。"; return }
        guard let recognizer, recognizer.isAvailable else {
            errorText = "当前无法使用语音识别。"; return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            self.request = request
            self.engine = engine
            transcript = ""
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if let error { self.errorText = error.localizedDescription; self.stop() }
                    else if result?.isFinal == true { self.stop() }
                }
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            errorText = nil
        } catch {
            errorText = "无法开始录音：\(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard let engine else { isRecording = false; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        self.engine = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
