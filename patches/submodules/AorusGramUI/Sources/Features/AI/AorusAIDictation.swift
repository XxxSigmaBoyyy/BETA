import Foundation
import AVFoundation
import Speech

/// Live dictation for the AorusAI composer.
///
/// The existing `VoiceTranscriptionManager` transcribes a finished file; the composer
/// needs the opposite — a microphone that streams partial results into the input while
/// the user is still speaking. Both permissions this needs are declared by the release
/// pipeline (`NSMicrophoneUsageDescription` ships upstream, and
/// `NSSpeechRecognitionUsageDescription` is added by `aorus_branding.py`), so the
/// authorization prompts are the system ones and never a crash.
final class AorusAIDictation {
    enum Failure {
        case notAuthorized
        case unavailable
        case engine

        var message: String {
            switch self {
            case .notAuthorized:
                return aorusAILocalized("Разрешите доступ к микрофону и распознаванию речи в Настройках", "Allow microphone and speech recognition access in Settings")
            case .unavailable:
                return aorusAILocalized("Распознавание речи недоступно для этого языка", "Speech recognition is unavailable for this language")
            case .engine:
                return aorusAILocalized("Не удалось включить микрофон", "Could not start the microphone")
            }
        }
    }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isTapInstalled = false

    private(set) var isRunning = false

    /// The transcription of the current run only, so the caller can append it to
    /// whatever the user had already typed instead of replacing it.
    private(set) var transcript = ""

    deinit {
        self.tearDown()
    }

    static func locale(for languageCode: String) -> Locale {
        let normalized = languageCode.lowercased()
        if normalized.hasPrefix("ru") {
            return Locale(identifier: "ru-RU")
        }
        if let exact = SFSpeechRecognizer.supportedLocales().first(where: { $0.identifier.lowercased().hasPrefix(normalized) }) {
            return exact
        }
        return Locale.current
    }

    /// Asks for both permissions and reports the outcome on the main queue.
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// Starts streaming. `onText` receives the transcription of this run every time it
    /// grows, `onFinish` is called exactly once when the run ends for any reason.
    func start(
        locale: Locale,
        onText: @escaping (String) -> Void,
        onFailure: @escaping (Failure) -> Void,
        onFinish: @escaping () -> Void
    ) {
        guard !self.isRunning else { return }
        self.transcript = ""

        self.requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                onFailure(.notAuthorized)
                onFinish()
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
                onFailure(.unavailable)
                onFinish()
                return
            }
            self.recognizer = recognizer

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                self.tearDown()
                onFailure(.engine)
                onFinish()
                return
            }

            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0.0, format.channelCount > 0 else {
                self.tearDown()
                onFailure(.engine)
                onFinish()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            self.isTapInstalled = true
            self.engine.prepare()
            do {
                try self.engine.start()
            } catch {
                self.tearDown()
                onFailure(.engine)
                onFinish()
                return
            }

            self.isRunning = true
            var didFinish = false
            let finishOnce: () -> Void = {
                guard !didFinish else { return }
                didFinish = true
                onFinish()
            }
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        onText(text)
                    }
                    if result.isFinal {
                        self.tearDown()
                        finishOnce()
                    }
                    return
                }
                if error != nil {
                    // A silent run ends with an error too; whatever was recognised is
                    // already in the composer, so this is not surfaced as a failure.
                    self.tearDown()
                    finishOnce()
                }
            }
        }
    }

    /// Ends the run. The recognizer delivers its final result through the callback
    /// passed to `start`, so the caller does not have to read anything back here.
    func stop() {
        guard self.isRunning else {
            self.tearDown()
            return
        }
        self.request?.endAudio()
        self.engine.pause()
    }

    private func tearDown() {
        if self.isTapInstalled {
            self.engine.inputNode.removeTap(onBus: 0)
            self.isTapInstalled = false
        }
        if self.engine.isRunning {
            self.engine.stop()
        }
        self.task?.cancel()
        self.task = nil
        self.request = nil
        self.recognizer = nil
        self.isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
