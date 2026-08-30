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
        case recognition

        var message: String {
            switch self {
            case .notAuthorized:
                return aorusAILocalized("Разрешите доступ к микрофону и распознаванию речи в Настройках", "Allow microphone and speech recognition access in Settings")
            case .unavailable:
                return aorusAILocalized("Распознавание речи недоступно для этого языка", "Speech recognition is unavailable for this language")
            case .engine:
                return aorusAILocalized("Не удалось включить микрофон", "Could not start the microphone")
            case .recognition:
                return aorusAILocalized("Не удалось распознать речь. Попробуйте ещё раз", "Could not recognize any speech. Please try again")
            }
        }
    }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isTapInstalled = false
    /// Held so the run can be ended by whichever of the recognizer, the user or the
    /// watchdog gets there first, and only once.
    private var finishHandler: (() -> Void)?
    private var runIdentifier = 0
    private var isStarting = false

    private(set) var isRunning = false
    var isActive: Bool { self.isStarting || self.isRunning }

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
        guard !self.isRunning, !self.isStarting else { return }
        self.transcript = ""
        self.isStarting = true
        self.runIdentifier += 1
        let expectedRunIdentifier = self.runIdentifier
        self.finishHandler = onFinish

        self.requestAuthorization { [weak self] granted in
            guard let self else { return }
            guard self.isStarting, self.runIdentifier == expectedRunIdentifier else { return }
            guard granted else {
                self.isStarting = false
                onFailure(.notAuthorized)
                self.finishRun()
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
                self.isStarting = false
                onFailure(.unavailable)
                self.finishRun()
                return
            }
            self.recognizer = recognizer

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            // On-device recognition is deliberately not forced. `supportsOnDeviceRecognition`
            // only says the recognizer could work offline; when the language asset has not
            // been downloaded the task fails on its first callback, and that failure was
            // swallowed — which is why dictation appeared to do nothing at all. Leaving the
            // choice to iOS keeps the server path available and it still prefers on-device
            // whenever the asset is there.
            self.request = request

            let session = AVAudioSession.sharedInstance()
            do {
                // `.duckOthers` is what Apple's own streaming-recognition sample asks for,
                // but it is documented as a playback option, so a session that refuses it
                // is retried without it rather than failing the whole run.
                do {
                    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                } catch {
                    try session.setCategory(.record, mode: .measurement)
                }
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                self.tearDown()
                onFailure(.engine)
                self.finishRun()
                return
            }

            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0.0, format.channelCount > 0 else {
                self.tearDown()
                onFailure(.engine)
                self.finishRun()
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
                self.finishRun()
                return
            }

            self.isStarting = false
            self.isRunning = true
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // `recognitionTask(with:resultHandler:)` makes no promise about its queue and
                // everything below writes to the composer, so hop to the main one first.
                DispatchQueue.main.async {
                    guard let self,
                          self.isRunning,
                          self.runIdentifier == expectedRunIdentifier else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.transcript {
                            self.transcript = text
                            onText(text)
                        }
                        if result.isFinal {
                            self.tearDown()
                            self.finishRun()
                        }
                        return
                    }
                    guard error != nil else { return }
                    // A run the user ended after speaking reports an error too, and its text
                    // is already in the composer. Only a run that recognised nothing is a
                    // real failure, and it has to say so rather than close in silence.
                    let recognizedNothing = self.transcript.isEmpty
                    self.tearDown()
                    if recognizedNothing {
                        onFailure(.recognition)
                    }
                    self.finishRun()
                }
            }
        }
    }

    /// Ends the run at most once, whichever of the recognizer, the user or the watchdog
    /// gets there first.
    private func finishRun() {
        guard let handler = self.finishHandler else { return }
        self.finishHandler = nil
        handler()
    }

    /// Ends the run. The recognizer delivers its final result through the callback
    /// passed to `start`, so the caller does not have to read anything back here.
    func stop() {
        if self.isStarting {
            // Permission prompts may outlive the overlay. Invalidate this attempt so a
            // late authorization callback cannot start recording after the user closed it.
            self.runIdentifier += 1
            self.isStarting = false
            self.tearDown()
            self.finishRun()
            return
        }
        guard self.isRunning else {
            self.tearDown()
            self.finishRun()
            return
        }
        self.request?.endAudio()
        self.engine.pause()
        // `endAudio()` normally draws a final result out of the recognizer, and that is
        // what ends the run. If it never arrives — a dropped connection, a task the system
        // cancelled — the overlay would stay up over the chat forever, so close the run
        // here instead. The identifier keeps a stale watchdog from ending a later run.
        let expected = self.runIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.runIdentifier == expected, self.finishHandler != nil else { return }
            self.tearDown()
            self.finishRun()
        }
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
        self.isStarting = false
        self.isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
