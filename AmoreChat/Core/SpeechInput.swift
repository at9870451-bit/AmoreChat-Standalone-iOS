import AVFoundation
import Foundation
import Observation
import Speech

/// The recognizer reports *replacements* for the current utterance, not appended words.
/// Keeping the session ID and callback order here makes late/duplicate callbacks harmless.
struct SpeechInputState {
    enum Phase: Equatable { case idle, starting, recording, finishing }

    private(set) var phase: Phase = .idle
    private(set) var sessionID = 0
    private(set) var transcript = ""
    private(set) var segmentID = 0
    var hasUncommittedText: Bool { !segmentText.isEmpty }
    private var committed = ""
    private var segmentText = ""
    private var lastCallback = 0

    private func joined(_ text: String) -> String {
        guard !committed.isEmpty, !text.isEmpty else { return committed + text }
        // Only add a word boundary for Latin text, not between Chinese characters.
        if let last = committed.unicodeScalars.last, let first = text.unicodeScalars.first,
           last.isASCII, first.isASCII, CharacterSet.letters.contains(first),
           CharacterSet.letters.contains(last) || ".!?".unicodeScalars.contains(last) {
            return committed + " " + text
        }
        return committed + text
    }

    mutating func begin() -> Int? {
        guard phase == .idle else { return nil }
        sessionID &+= 1
        segmentID = 0
        lastCallback = 0
        committed = ""
        segmentText = ""
        transcript = ""
        phase = .starting
        return sessionID
    }

    mutating func started(_ id: Int) -> Bool {
        guard id == sessionID, phase == .starting else { return false }
        phase = .recording
        return true
    }

    mutating func stopping(_ id: Int) -> Bool {
        guard id == sessionID, phase == .recording else { return false }
        phase = .finishing
        return true
    }

    mutating func partial(_ text: String, id: Int, callback: Int, segment: Int = 0) -> Bool {
        guard id == sessionID, segment == segmentID,
              phase == .recording || phase == .finishing,
              callback > lastCallback else { return false }
        lastCallback = callback
        segmentText = text
        let fullText = joined(text)
        guard transcript != fullText else { return false }
        transcript = fullText
        return true
    }

    /// A natural final (e.g. a pause) completes one segment, not the user's recording.
    mutating func rollSegment(_ text: String?, id: Int, callback: Int, segment: Int) -> Bool {
        guard id == sessionID, phase == .recording, segment == segmentID,
              callback > lastCallback else { return false }
        lastCallback = callback
        committed = joined(text.flatMap { $0.isEmpty ? nil : $0 } ?? segmentText)
        segmentText = ""
        transcript = committed
        segmentID &+= 1
        lastCallback = 0 // Each recognition task has its own callback sequence.
        return true
    }

    /// Returns nil for a stale completion and .some("") for a valid empty completion.
    mutating func complete(_ text: String?, id: Int, callback: Int? = nil, segment: Int? = nil) -> String? {
        guard id == sessionID, phase == .recording || phase == .finishing,
              segment == nil || segment == segmentID else { return nil }
        if let callback {
            guard callback > lastCallback else { return nil }
            lastCallback = callback
        }
        if let text, !text.isEmpty { segmentText = text }
        transcript = joined(segmentText)
        phase = .idle
        return transcript
    }

    mutating func abandon(_ id: Int) -> Bool {
        guard id == sessionID, phase != .idle else { return false }
        phase = .idle
        transcript = ""
        return true
    }
}

/// Serializes append/endAudio across AVAudioEngine's real-time callback and the UI actor.
private final class SpeechBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }

    func replace(with next: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = next
    }

    func endAudio() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}

private final class SpeechCallbackSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor @Observable final class SpeechInput {
    /// Live replacement text. Observe this or use onPartial; never append each partial to a draft.
    var transcript = ""
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var isFinishing = false
    var errorText: String?

    /// A partial is the entire current utterance. Called on the main actor when it changes.
    @ObservationIgnored var onPartial: ((String) -> Void)?
    /// Called once per *started* session, after stop/final/error, with the best available text.
    /// May be empty. A user cancel or permission failure does not call this closure.
    @ObservationIgnored var onCompletion: ((String) -> Void)?

    @ObservationIgnored private var state = SpeechInputState()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var tappedInput: AVAudioInputNode?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sink: SpeechBufferSink?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var sessionActivated = false
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?

    func toggle() async {
        if isRecording || isStarting { stop() }
        else if !isFinishing { await start() }
    }

    /// Starts streaming microphone buffers immediately after both system permissions are granted.
    /// Defaults to the app's original Chinese recognizer; callers can supply another locale.
    func start(locale: Locale = Locale(identifier: "zh-CN")) async {
        guard let id = state.begin() else { return }
        updatePhase()
        transcript = ""
        errorText = nil

        let speechAuthorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if SFSpeechRecognizer.authorizationStatus() == .authorized {
                continuation.resume(returning: true)
            } else {
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
        guard state.sessionID == id, state.phase == .starting else { return }
        guard speechAuthorized else { failStart(id, message: "请在系统设置中允许语音识别。"); return }
        let microphoneAuthorized = await AVAudioApplication.requestRecordPermission()
        guard state.sessionID == id, state.phase == .starting else { return }
        guard microphoneAuthorized else { failStart(id, message: "请在系统设置中允许麦克风。"); return }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            failStart(id, message: "当前无法使用语音识别。")
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActivated = true
            guard audioSession.isInputAvailable else {
                failStart(id, message: "找不到可用的麦克风，请检查音频设备。")
                return
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                failStart(id, message: "无法读取麦克风音频格式，请重新连接音频设备。")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let sink = SpeechBufferSink(request)
            self.engine = engine
            self.recognizer = recognizer
            self.request = request
            self.sink = sink
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [sink] buffer, _ in
                sink.append(buffer)
            }
            tapInstalled = true
            tappedInput = input
            launchRecognition(recognizer: recognizer, request: request, id: id, segment: 0)
            engine.prepare()
            try engine.start()
            _ = state.started(id)
            updatePhase()
            observeAudioChanges(engine: engine, id: id)
        } catch {
            failStart(id, message: "无法开始录音：\(error.localizedDescription)")
        }
    }

    /// Stops the tap now, then waits briefly for Apple's final recognition result.
    /// Completion (not the synchronous value of transcript) is the text to commit.
    func stop() {
        let id = state.sessionID
        if state.phase == .starting {
            cancel() // Permission prompt/start in progress: no audio to finalize.
            return
        }
        guard state.stopping(id) else { return }
        updatePhase()
        stopCapture()
        if task == nil { finish(id: id, text: nil); return }
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.finish(id: id, text: nil) // Last genuine partial, if no final arrives.
        }
    }

    /// Discard speech (e.g. changing conversations). No completion is delivered.
    func cancel() {
        let id = state.sessionID
        guard state.abandon(id) else { return }
        releaseResources()
        transcript = ""
        updatePhase()
    }

    private func launchRecognition(recognizer: SFSpeechRecognizer,
                                   request: SFSpeechAudioBufferRecognitionRequest,
                                   id: Int, segment: Int) {
        let callbackSequence = SpeechCallbackSequence()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            let order = callbackSequence.next()
            Task { @MainActor [weak self] in
                self?.receive(text: text, isFinal: isFinal, error: errorMessage,
                              id: id, segment: segment, callback: order)
            }
        }
    }

    private func rollRecognition(id: Int, segment: Int, text: String?, callback: Int) {
        guard state.rollSegment(text, id: id, callback: callback, segment: segment) else { return }
        transcript = state.transcript
        onPartial?(transcript)
        guard state.sessionID == id, state.phase == .recording else { return }
        guard let recognizer, let sink, recognizer.isAvailable else {
            errorText = "当前无法继续语音识别，请重新点击麦克风。"
            finish(id: id, text: nil)
            return
        }
        // Keep the engine/tap alive; swap requests under the sink lock so no audio
        // buffer can be appended after endAudio or to both recognition tasks.
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.taskHint = .dictation
        sink.replace(with: next)
        task?.cancel()
        request = next
        launchRecognition(recognizer: recognizer, request: next,
                          id: id, segment: state.segmentID)
    }

    private func receive(text: String?, isFinal: Bool, error: String?,
                         id: Int, segment: Int, callback: Int) {
        guard state.sessionID == id, state.segmentID == segment else { return }
        if isFinal {
            if state.phase == .recording {
                if (text ?? "").isEmpty && !state.hasUncommittedText {
                    errorText = "语音识别已结束且未返回新文字，请重新点击麦克风。"
                    finish(id: id, text: nil, callback: callback, segment: segment)
                } else {
                    rollRecognition(id: id, segment: segment, text: text, callback: callback)
                }
            } else {
                finish(id: id, text: text, callback: callback, segment: segment)
            }
        } else if let error {
            if state.phase == .recording || (state.phase == .finishing && state.transcript.isEmpty) {
                errorText = "语音识别中断：\(error)"
            }
            finish(id: id, text: text, callback: callback, segment: segment)
        } else if let text, state.partial(text, id: id, callback: callback, segment: segment) {
            transcript = state.transcript
            onPartial?(transcript)
        }
    }

    private func finish(id: Int, text: String?, callback: Int? = nil, segment: Int? = nil) {
        guard let finalText = state.complete(text, id: id, callback: callback, segment: segment) else { return }
        releaseResources() // Invalidates the tap before cancelling the recognition task.
        transcript = finalText
        updatePhase()
        onCompletion?(finalText)
    }

    private func failStart(_ id: Int, message: String) {
        guard state.abandon(id) else { return }
        releaseResources()
        updatePhase()
        errorText = message
    }

    private func updatePhase() {
        isStarting = state.phase == .starting
        isRecording = state.phase == .recording
        isFinishing = state.phase == .finishing
    }

    private func stopCapture() {
        // Engine.stop first quiesces the tap; the flag guarantees exactly one removeTap.
        if let engine {
            engine.stop()
            if tapInstalled {
                tapInstalled = false
                tappedInput?.removeTap(onBus: 0)
            }
            tappedInput = nil
            self.engine = nil
        }
        sink?.endAudio() // Also prevents an in-flight callback appending after endAudio.
        sink = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
    }

    private func releaseResources() {
        finishTimeout?.cancel()
        finishTimeout = nil
        stopCapture()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        if sessionActivated {
            sessionActivated = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func observeAudioChanges(engine: AVAudioEngine, id: Int) {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                       object: nil, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.audioChanged(id: id, message: "录音被其他音频中断，请重新点击麦克风继续。")
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                       object: nil, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                switch reason {
                case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange,
                     .noSuitableRouteForCategory:
                    self?.audioChanged(id: id, message: "麦克风设备已切换，请重新点击麦克风继续。")
                default: break
                }
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                       object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioChanged(id: id, message: "音频服务已重置，请重新点击麦克风继续。")
            }
        })
        notificationTokens.append(center.addObserver(forName: Notification.Name.AVAudioEngineConfigurationChange,
                                                       object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioChanged(id: id, message: "音频配置已更改，请重新点击麦克风继续。")
            }
        })
    }

    private func audioChanged(id: Int, message: String) {
        guard id == state.sessionID, state.phase == .recording else { return }
        errorText = message
        stop() // Safe finish of existing partial; a fresh tap/format is created on next start.
    }
}
