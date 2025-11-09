import Foundation
import AVFoundation
import Speech
import Combine

/// Robust speech controller with safe start/stop + lightweight command parsing.
final class VoiceControl: NSObject, ObservableObject {

    static let shared = VoiceControl()

    @Published private(set) var isListening = false
    @Published private(set) var transcript: String = ""

    /// Called on *main thread* when a command is recognized.
    var onCommand: ((Command) -> Void)?

    // MARK: - Command model

    enum AppName: String, CaseInsensitiveString {
        case youtube, netflix, prime, hotstar, jiocinema, sonyliv
    }

    enum Command: Equatable {
        case volumeUp, volumeDown
        case muteOn, muteOff, muteToggle
        case powerOn, powerOff
        case channelUp, channelDown
        case open(AppName)
        case navUp, navDown, navLeft, navRight, ok, back, home
        case unknown(String)
    }

    // MARK: - Speech internals

    private let audioEngine = AVAudioEngine()
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.current.identifier))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    private let session = AVAudioSession.sharedInstance()
    private let workQueue = DispatchQueue(label: "VoiceControlQueue")

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: nil)
    }

    // MARK: - Public API

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async { completion(auth == .authorized) }
        }
    }

    func start() {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.isListening { return }
            self.prepareSpeech { ok, err in
                guard ok else {
                    print("Speech prepare failed: \(err ?? "unknown")")
                    return
                }
                self.beginRecording()
            }
        }
    }

    func stop() {
        workQueue.async { [weak self] in
            self?.teardown()
        }
    }

    // MARK: - Internals

    private func prepareSpeech(_ completion: @escaping (Bool, String?) -> Void) {
        teardown()

        guard let recognizer, recognizer.isAvailable else {
            completion(false, "Speech recognizer not available")
            return
        }

        do {
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try session.setPreferredIOBufferDuration(0.010)
        } catch {
            completion(false, "Audio session error: \(error.localizedDescription)")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        recognitionRequest = req

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.transcript = text }
                if result.isFinal {
                    self.handleFinalTranscript(text)
                    self.workQueue.async { self.teardown() }
                }
            }
            if let error = error {
                print("Recognition error: \(error.localizedDescription)")
                self.workQueue.async { self.teardown() }
            }
        }

        completion(true, nil)
    }

    private func beginRecording() {
        let input = audioEngine.inputNode
        removeInputTapIfPresent(on: input)

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let req = self.recognitionRequest else { return }
            req.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Audio engine start error: \(error.localizedDescription)")
            teardown()
            return
        }

        DispatchQueue.main.async { self.isListening = true }
    }

    private func teardown() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            removeInputTapIfPresent(on: audioEngine.inputNode)
            audioEngine.stop()
        }
        audioEngine.reset()

        DispatchQueue.main.async { self.isListening = false }
    }

    private func removeInputTapIfPresent(on node: AVAudioInputNode) {
        node.removeTap(onBus: 0)
    }

    // MARK: - Command parsing

    private func handleFinalTranscript(_ text: String) {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Basic intents
        if t.containsOne(of: ["volume up","sound up","louder","increase volume","vol up"]) {
            fire(.volumeUp); return
        }
        if t.containsOne(of: ["volume down","sound down","softer","decrease volume","vol down"]) {
            fire(.volumeDown); return
        }
        if t.matchesWord("mute on") || t == "mute" || t.contains("mute tv") {
            fire(.muteOn); return
        }
        if t.matchesWord("mute off") || t.containsOne(of: ["unmute","un-mute","sound on"]) {
            fire(.muteOff); return
        }
        if t.containsOne(of: ["toggle mute","toggle sound"]) {
            fire(.muteToggle); return
        }

        if t.containsOne(of: ["power off","turn off tv","switch off tv","tv off"]) {
            fire(.powerOff); return
        }
        if t.containsOne(of: ["power on","turn on tv","switch on tv","tv on"]) {
            fire(.powerOn); return
        }

        if t.containsOne(of: ["channel up","next channel"]) {
            fire(.channelUp); return
        }
        if t.containsOne(of: ["channel down","previous channel","prev channel"]) {
            fire(.channelDown); return
        }

        if t.matchesWord("home") || t.containsOne(of: ["go home","open home"]) {
            fire(.home); return
        }
        if t.matchesWord("back") || t.contains("go back") {
            fire(.back); return
        }
        if t.matchesWord("ok") || t.containsOne(of: ["select","enter"]) {
            fire(.ok); return
        }
        if t.matchesWord("up") { fire(.navUp); return }
        if t.matchesWord("down") { fire(.navDown); return }
        if t.matchesWord("left") { fire(.navLeft); return }
        if t.matchesWord("right") { fire(.navRight); return }

        // App launchers
        if let app = detectApp(in: t) {
            fire(.open(app)); return
        }

        // Fallback
        fire(.unknown(text))
    }

    private func detectApp(in t: String) -> AppName? {
        if t.contains("you tube") || t.contains("youtube") { return .youtube }
        if t.contains("netflix") { return .netflix }
        if t.contains("prime") || t.contains("amazon") { return .prime }
        if t.contains("hotstar") || t.contains("disney") { return .hotstar }
        if t.contains("jio cinema") || t.contains("jiocinema") { return .jiocinema }
        if t.contains("sony liv") || t.contains("sonyliv") { return .sonyliv }
        return nil
    }

    private func fire(_ cmd: Command) {
        DispatchQueue.main.async { self.onCommand?(cmd) }
    }

    // MARK: - Notifications

    @objc private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        if type == .began { workQueue.async { self.teardown() } }
    }

    @objc private func handleRouteChange(_ n: Notification) {
        guard let info = n.userInfo,
              let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
        if reason == .oldDeviceUnavailable {
            workQueue.async { self.teardown() }
        }
    }
}

// MARK: - Small helpers

fileprivate protocol CaseInsensitiveString: RawRepresentable where RawValue == String {}
extension CaseInsensitiveString {
    init?(_ raw: String) {
        if let v = Self.allCases.first(where: { ($0 as! Self).rawValue.lowercased() == raw.lowercased() }) as? Self {
            self = v
        } else { return nil }
    }
    static var allCases: [Self] { [] } // unused; just to satisfy protocol requirement
}

fileprivate extension String {
    func containsOne(of arr: [String]) -> Bool {
        let s = self
        return arr.contains { s.contains($0) }
    }
    func matchesWord(_ word: String) -> Bool {
        let s = " " + self + " "
        let w = " " + word + " "
        return s.contains(w)
    }
}

