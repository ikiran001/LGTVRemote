// WebOSTV.swift
// Combined and patched: pointer-first remote, robust retries, app fallbacks,
// fetchMacAddress helper, filtering unwanted keys.

import Foundation
import Combine

final class WebOSTV: ObservableObject {

    // MARK: Published state for UI
    @Published private(set) var isConnected = false     // true only after "registered"
    @Published private(set) var ip: String = ""
    @Published private(set) var lastMessage: String = ""

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    // Internals
    private var socket: WebOSSocket?
    private var nextId = 1
    private var registered = false
    private var connectCompletion: ((Bool, String) -> Void)?
    private var pendingResponses: [String: (Result<[String: Any], Error>) -> Void] = [:]

    // Input / pointer management
    private var inputRemotePrimed = false
    private var inputRemotePriming = false
    private var queuedButtons: [String] = []
    private var retryingButtonKey: String?
    private var failedButtonServices: Set<String> = []

    private struct InputRemoteService: Equatable {
        let registerURI: String
        let sendButtonURI: String
    }

    private struct PointerService {
        let requestURI: String
    }

    // Candidate button services (common variants)
    private let inputRemoteButtonCandidates: [InputRemoteService] = [
        InputRemoteService(registerURI: "ssap://com.webos.service.tv.inputremote/register",
                           sendButtonURI: "ssap://com.webos.service.tv.inputremote/sendButton"),
        InputRemoteService(registerURI: "ssap://com.webos.service.remoteinput/register",
                           sendButtonURI: "ssap://com.webos.service.remoteinput/sendButton"),
        InputRemoteService(registerURI: "ssap://com.webos.service.tvinputremote/register",
                           sendButtonURI: "ssap://com.webos.service.tvinputremote/sendButton")
    ]

    // Candidate pointer service URIs
    private let pointerServiceCandidates: [PointerService] = [
        PointerService(requestURI: "ssap://com.webos.service.tv.inputremote/getPointerInputSocket"),
        PointerService(requestURI: "ssap://com.webos.service.networkinput/getPointerInputSocket"),
        PointerService(requestURI: "ssap://com.webos.service.tvpointer/getPointerInputSocket")
    ]

    private var activeInputRemoteService: InputRemoteService?
    private var pointerSocket: PointerSocket?
    private var clientKey: String? = WebOSTV.savedClientKey

    // Extended fallback app mapping
    private struct StreamingAppFallback {
        let alternates: [String]
        let keywordGroups: [[String]]
    }

    private let streamingAppFallbacks: [String: StreamingAppFallback] = {
        let prime = StreamingAppFallback(
            alternates: [
                "amazon-webos", "amazon-webos-us", "primevideo", "com.amazon.amazonvideo.webos",
                "com.amazon.ignition", "amazonprimevideo", "com.webos.app.amazonprimevideo",
                "com.amazon.shoptv.webos", "primevideo-webos", "amazonprimevideo-webos", "amzn.tvarm"
            ],
            keywordGroups: [["prime","video"], ["amazon","prime"], ["prime"]]
        )
        let netflix = StreamingAppFallback(
            alternates: ["netflix", "com.netflix.app"],
            keywordGroups: [["netflix"]]
        )
        let hotstar = StreamingAppFallback(
            alternates: ["disneyplus-hotstar", "hotstar", "com.disney.disneyplus-in", "com.star.hotstar", "disney.hotstar"],
            keywordGroups: [["hotstar"], ["disney","hotstar"], ["disney"]]
        )
        let sonyLiv = StreamingAppFallback(
            alternates: ["sonyliv-webos", "com.sonyliv", "com.sonyliv.sonyliv", "sonyliv", "in.sonyliv.webos"],
            keywordGroups: [["sony","liv"], ["sonyliv"], ["sony"]]
        )
        let jioCinema = StreamingAppFallback(
            alternates: [
                "com.jio.media.jioplay", "jiocinema", "com.jio.media.ondemand",
                "com.jio.jioplay.tv", "com.jio.jioplay", "com.jio.media.jioplay.tv",
                "jiocinema-webos", "com.reliance.jiocinema"
            ],
            keywordGroups: [["jio","cinema"], ["jiocinema"], ["jio"]]
        )

        var map: [String: StreamingAppFallback] = [:]
        let groups: [(keys:[String], fallback: StreamingAppFallback)] = [
            (["amzn.tvarm","amazon-webos","primevideo","com.amazon.amazonvideo.webos"], prime),
            (["netflix","com.netflix.app"], netflix),
            (["com.startv.hotstar.lg", "disneyplus-hotstar","hotstar"], hotstar),
            (["com.sonyliv.lg","sonyliv-webos","com.sonyliv"], sonyLiv),
            (["com.jio.media.jioplay.tv","com.jio.media.jioplay","jiocinema"], jioCinema)
        ]

        for (keys, fallback) in groups {
            for k in keys { map[k] = fallback }
            for alt in fallback.alternates { map[alt] = fallback }
        }
        return map
    }()

    private let streamingAppDisplayNames: [String: String] = [
        "amzn.tvarm": "Prime Video",
        "amazon-webos": "Prime Video",
        "primevideo": "Prime Video",
        "netflix": "Netflix",
        "com.startv.hotstar.lg": "Disney+ Hotstar",
        "com.sonyliv.lg": "Sony LIV",
        "com.jio.media.jioplay.tv": "JioCinema"
    ]

    // Persisted convenience
    static var savedIP: String?  { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP") }
    static var savedMAC: String? { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") }
    private static var savedClientKey: String? {
        get { UserDefaults.standard.string(forKey: "LGRemoteMVP.clientKey") }
        set { UserDefaults.standard.setValue(newValue, forKey: "LGRemoteMVP.clientKey") }
    }

    // MARK: - Connect

    /// Connect, but first do a fast TCP reachability check for nicer UX.
    func connect(ip: String, completion: @escaping (Bool, String) -> Void) {
        self.ip = ip
        connectCompletion = completion
        registered = false
        isConnected = false
        inputRemotePrimed = false
        inputRemotePriming = false
        queuedButtons.removeAll()
        retryingButtonKey = nil
        failedButtonServices.removeAll()
        pointerSocket?.close()
        pointerSocket = nil
        activeInputRemoteService = nil
        clientKey = WebOSTV.savedClientKey
        cancelAllPendingRequests(message: "Previous requests cancelled")
        lastMessage = "Pinging \(ip)…"

        // 1) quick reachability (uses Ping.swift)
        Ping.isReachable(ip: ip, port: 3000, timeout: 0.7) { [weak self] reachable in
            guard let self else { return }
            if !reachable {
                Ping.isReachable(ip: ip, port: 3001, timeout: 0.7) { [weak self] reachable2 in
                    guard let self else { return }
                    if !reachable2 {
                        DispatchQueue.main.async {
                            self.lastMessage = "TV at \(ip) didn’t respond on 3000/3001. Check Wi-Fi / LG Connect Apps."
                        }
                        self.completeConnect(false, "Host not reachable")
                        return
                    }
                    self.openSocketAndRegister()
                }
            } else {
                self.openSocketAndRegister()
            }
        }
    }

    // MARK: - Request helpers (with retry on server errors)

    private func nextRequestId(_ prefix: String) -> String {
        defer { nextId += 1 }
        return "\(prefix)-\(nextId)"
    }

    private func send(_ object: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard registered, let sock = socket else {
            completion?(NSError(domain: "WebOSTV", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Not registered/connected"]))
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            completion?(NSError(domain: "WebOSTV", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "Encode error"]))
            return
        }
        sock.send(text, completion: completion)
    }

    /// sendSimple with retry on 5xx server errors (exponential-ish backoff)
    func sendSimple(uri: String,
                    payload: [String: Any] = [:],
                    retries: Int = 2,
                    completion: ((Result<[String: Any], Error>) -> Void)? = nil) {

        guard registered else {
            completion?(.failure(makeTVError("TV not registered yet", code: -3)))
            return
        }

        let requestId = nextRequestId("req")
        let req: [String: Any] = [
            "id": requestId,
            "type": "request",
            "uri": uri,
            "payload": payload
        ]

        if let completion {
            pendingResponses[requestId] = completion
        }

        func attemptSend(remaining: Int, delay: TimeInterval = 0.0) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.send(req) { error in
                    if let error,
                       self.shouldRetryForError(error) && remaining > 0 {
                        let backoff = Double( (2 * (2 - remaining + 1)) ) * 0.18
                        attemptSend(remaining: remaining - 1, delay: backoff)
                        return
                    }
                    if let error {
                        if let handler = self.pendingResponses.removeValue(forKey: requestId) {
                            DispatchQueue.main.async { handler(.failure(error)) }
                        }
                    }
                }
            }
        }

        attemptSend(remaining: retries)
    }

    private func shouldRetryForError(_ error: Error) -> Bool {
        let ns = error as NSError
        if let code = ns.userInfo["errorCode"] as? Int, (500...599).contains(code) { return true }
        if (500...599).contains(ns.code) { return true }
        if ns.domain == NSURLErrorDomain { return true }
        return false
    }

    // MARK: Button sending — FORCE pointer mode when possible, filter unwanted keys

    /// Public entry used by UI
    func sendButton(key: String) {
        sendButton(key: key, allowQueue: true)
    }

    // Map UI labels to TV key names
    private func tvKeyName(for uiKey: String) -> String {
        let k = uiKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch k {
            case "up": return "UP"
            case "down": return "DOWN"
            case "left": return "LEFT"
            case "right": return "RIGHT"
            case "ok", "enter", "select": return "ENTER"
            case "volup", "volumeup", "volume_up": return "VOLUMEUP"
            case "voldown", "volumedown", "volume_down": return "VOLUMEDOWN"
            case "mute": return "MUTE"
            case "home": return "HOME"
            case "back", "return": return "BACK"
            case "power", "power_toggle", "tv_power": return "POWER"
            case "play": return "PLAY"
            case "pause": return "PAUSE"
            case "stop": return "STOP"
            case "rew", "rewind": return "REWIND"
            case "ff", "forward", "fwd": return "FASTFORWARD"
            default: return uiKey.uppercased()
        }
    }

    // Decide if a key should be filtered out entirely (user requested)
    private func shouldFilterOutKey(_ uiKey: String) -> Bool {
        let lower = uiKey.lowercased()
        if lower == "rew" || lower == "rewind" { return true }
        if lower == "play" || lower == "pause" { return true }
        if lower == "frd" { return true } // remove custom frd label
        return false
    }

    // Core robust send with pointer-first approach and queued fallback
    private func sendButton(key: String, allowQueue: Bool) {
        // 1) filter out keys that should be removed
        if shouldFilterOutKey(key) { return }

        // 2) normalize to tv key
        let tvKey = tvKeyName(for: key)

        // 3) if pointer socket ready -> send
        if let pointer = pointerSocket, pointer.isReady {
            pointer.sendButton(tvKey)
            if retryingButtonKey == key { retryingButtonKey = nil }
            return
        }

        // 4) if input-remote service active -> try RPC and fallback to pointer if 5xx
        if inputRemotePrimed, let service = activeInputRemoteService {
            sendSimple(uri: service.sendButtonURI, payload: ["name": tvKey], retries: 2) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    if self.retryingButtonKey == key { self.retryingButtonKey = nil }
                case .failure(let error):
                    if self.shouldFallbackToPointer(for: error) {
                        if allowQueue { self.enqueueButtonForRetry(tvKey, prioritizingFront: true) }
                        self.ensurePointerSocket(force: true)
                    } else if allowQueue {
                        self.enqueueButtonForRetry(tvKey, prioritizingFront: false)
                    } else {
                        DispatchQueue.main.async { self.lastMessage = "Button failed: \(error.localizedDescription)" }
                    }
                }
            }
            return
        }

        // 5) If no transport primed: queue and attempt pointer and input-service discovery
        if allowQueue {
            enqueueButtonForRetry(tvKey, prioritizingFront: false)
            ensurePointerSocket(force: false)
            ensureInputRemoteReady(force: false)
        }
    }

    // MARK: Pointer socket helpers

    /// Ensure pointer socket is open (tries pointer services). If force -> close existing and reopen.
    private func ensurePointerSocket(force: Bool = false) {
        guard registered else { return }
        if inputRemotePriming && !force { return }
        if !force, pointerSocket?.isReady == true { inputRemotePrimed = true; return }

        if force {
            pointerSocket?.close()
            pointerSocket = nil
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.primePointerService(at: 0, collectedError: nil)
        }
    }

    private func primePointerService(at index: Int, collectedError: Error?) {
        guard registered else { finalizeInputRemotePrime(error: collectedError); return }
        guard !pointerServiceCandidates.isEmpty else { finalizeInputRemotePrime(error: collectedError); return }
        guard index < pointerServiceCandidates.count else { finalizeInputRemotePrime(error: collectedError); return }

        let candidate = pointerServiceCandidates[index]
        sendSimple(uri: candidate.requestURI, payload: [:], retries: 1) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                let urls = self.pointerSocketURLs(from: payload)
                guard !urls.isEmpty else {
                    self.primePointerService(at: index + 1, collectedError: collectedError)
                    return
                }
                self.openPointerSocket(with: urls) { (success: Bool, error: Error?) in
                    if success {
                        self.activeInputRemoteService = nil
                        self.inputRemotePrimed = true
                        self.inputRemotePriming = false
                        self.lastMessage = "Input remote ready (pointer)"
                        self.flushQueuedButtons()
                    } else {
                        if let socket = self.pointerSocket {
                            socket.close()
                        }
                        self.pointerSocket = nil
                        let aggregated = error ?? collectedError
                        self.primePointerService(at: index + 1, collectedError: aggregated)
                    }
                }
            case .failure:
                self.primePointerService(at: index + 1, collectedError: collectedError)
            }
        }
    }

    private func openPointerSocket(with urls: [URL], completion: @escaping (Bool, Error?) -> Void) {
        guard !urls.isEmpty else {
            completion(false, makeTVError("Pointer socket path missing", code: -15))
            return
        }

        let socket = PointerSocket(host: ip, clientKey: clientKey, allowInsecureLocalTLS: true)
        pointerSocket = socket

        socket.onDisconnect = { [weak self, weak socket] error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let socket, self.pointerSocket === socket else { return }
                self.pointerSocket = nil
                self.inputRemotePrimed = false
                self.activeInputRemoteService = nil
                if let error {
                    if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
                        self.lastMessage = "Pointer connection lost, retrying…"
                    } else {
                        self.lastMessage = "Pointer input disconnected: \(error.localizedDescription)"
                    }
                } else {
                    self.lastMessage = "Pointer connection closed, retrying…"
                }
                // try again (aggressive)
                self.ensurePointerSocket(force: true)
            }
        }

        socket.connect(urls: urls) { [weak self, weak socket] (success: Bool, error: Error?) in
            guard let self else { return }
            DispatchQueue.main.async {
                if !success, let socket, self.pointerSocket === socket {
                    self.pointerSocket = nil
                }
                completion(success, error)
            }
        }
    }

    // MARK: Input remote priming (button RPCs) — tolerant

    private func ensureInputRemoteReady(force: Bool = false) {
        guard registered else { return }

        if inputRemotePriming { return }
        if !force && inputRemotePrimed { return }
        if !force, pointerSocket?.isReady == true {
            inputRemotePrimed = true
            return
        }

        inputRemotePriming = true

        if force {
            pointerSocket?.close()
            pointerSocket = nil
        }
        activeInputRemoteService = nil

        primeButtonService(at: 0, collectedError: nil)
    }

    private func primeButtonService(at index: Int, collectedError: Error?) {
        guard registered else { finalizeInputRemotePrime(error: collectedError); return }

        var searchIndex = index
        while searchIndex < inputRemoteButtonCandidates.count {
            let service = inputRemoteButtonCandidates[searchIndex]
            if failedButtonServices.contains(service.registerURI) {
                searchIndex += 1
                continue
            }
            let payload = inputRemoteRegisterPayload()
            let currentIndex = searchIndex
            sendSimple(uri: service.registerURI, payload: payload, retries: 1) { [weak self] (result: Result<[String:Any], Error>) in
                guard let self else { return }
                switch result {
                case .success:
                    self.pointerSocket?.close()
                    self.pointerSocket = nil
                    self.activeInputRemoteService = service
                    self.inputRemotePrimed = true
                    self.inputRemotePriming = false
                    self.lastMessage = "Input remote ready (buttons)"
                    self.flushQueuedButtons()
                case .failure(let error):
                    self.failedButtonServices.insert(service.registerURI)
                    // try next service
                    self.primeButtonService(at: currentIndex + 1, collectedError: error)
                }
            }
            return
        }

        // No button service found, attempt pointer
        primePointerService(at: 0, collectedError: collectedError)
    }

    private func finalizeInputRemotePrime(error: Error?) {
        inputRemotePriming = false
        inputRemotePrimed = false
        activeInputRemoteService = nil
        if let error {
            lastMessage = "Input remote unavailable: \(error.localizedDescription)"
        } else {
            lastMessage = "Input remote unavailable"
        }
    }

    // MARK: Queue helpers

    private func flushQueuedButtons() {
        guard !queuedButtons.isEmpty else { return }
        let pending = queuedButtons
        queuedButtons.removeAll()
        retryingButtonKey = nil
        for key in pending {
            // when flushing, do not allow queueing again (avoid infinite retries)
            sendButton(key: key, allowQueue: false)
        }
    }

    private func enqueueButtonForRetry(_ key: String, prioritizingFront: Bool) {
        queuedButtons.removeAll { $0 == key }
        if prioritizingFront {
            queuedButtons.insert(key, at: 0)
        } else {
            queuedButtons.append(key)
        }
        if queuedButtons.count > 60 {
            queuedButtons = Array(queuedButtons.suffix(60))
        }
    }

    // MARK: App launching with fallback and retries

    func launchStreamingApp(_ appId: String) {
        attemptLaunch(appId: appId, originalKey: appId, tried: [])
    }

    private func attemptLaunch(appId: String, originalKey: String, tried: Set<String>) {
        DispatchQueue.main.async { self.lastMessage = "Launching \(self.displayName(for: appId))…" }
        sendSimple(uri: "ssap://system.launcher/launch", payload: ["id": appId], retries: 2) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                break
            case .failure(let error):
                let updatedTried = tried.union([appId.lowercased()])
                self.handleLaunchFailure(originalKey: originalKey, tried: updatedTried, error: error)
            }
        }
    }

    private func handleLaunchFailure(originalKey: String, tried: Set<String>, error: Error) {
        let message = error.localizedDescription
        guard isRecoverableLaunchError(message, error: error) else {
            DispatchQueue.main.async {
                self.lastMessage = "\(self.displayName(for: originalKey)) launch failed: \(message)"
            }
            return
        }

        resolveNextAppId(originalKey: originalKey, tried: tried) { [weak self] nextId in
            guard let self else { return }
            guard let nextId else {
                DispatchQueue.main.async {
                    self.lastMessage = "\(self.displayName(for: originalKey)) launch failed: \(message)"
                }
                return
            }
            DispatchQueue.main.async {
                self.lastMessage = "Retrying \(self.displayName(for: originalKey)) as \(self.displayName(for: nextId))…"
            }
            self.attemptLaunch(appId: nextId, originalKey: originalKey, tried: tried)
        }
    }

    private func displayName(for appId: String) -> String {
        let key = appId.lowercased()
        return streamingAppDisplayNames[key] ?? appId
    }

    private func isRecoverableLaunchError(_ message: String, error: Error) -> Bool {
        let lower = message.lowercased()
        if lower.contains("no such app") || lower.contains("no such application") || lower.contains("not installed") || lower.contains("no such service") || lower.contains("not exist") { return true }
        if lower.contains("internal server error") || lower.contains("internal error") || lower.contains("application error") || lower.contains("500") || lower.contains("404") { return true }
        let ns = error as NSError
        if (400...599).contains(ns.code) { return true }
        if let code = ns.userInfo["errorCode"] as? Int, (400...599).contains(code) { return true }
        return false
    }

    private func resolveNextAppId(originalKey: String, tried: Set<String>, completion: @escaping (String?) -> Void) {
        let lower = originalKey.lowercased()
        if let fallback = streamingAppFallbacks[lower] {
            for alt in fallback.alternates {
                if !tried.contains(alt.lowercased()) {
                    completion(alt)
                    return
                }
            }
        }
        // try keyword match in fallback map
        for (key, fallback) in streamingAppFallbacks {
            if tried.contains(key) { continue }
            for group in fallback.keywordGroups {
                let matches = group.allSatisfy { lower.contains($0) || key.contains($0) }
                if matches && !tried.contains(key) {
                    completion(key)
                    return
                }
            }
        }
        // As last resort attempt discovering installed apps (async)
        fetchLaunchPoints { apps in
            // pick first app id not tried that looks similar
            for app in apps {
                let id = app["id"] as? String ?? ""
                let lid = id.lowercased()
                if !tried.contains(lid) {
                    if lid.contains(lower) || lower.contains(lid) {
                        completion(id)
                        return
                    }
                }
            }
            completion(nil)
        }
    }

    // MARK: Socket open / register / pairing

    private func openSocketAndRegister() {
        DispatchQueue.main.async { self.lastMessage = "Opening socket…" }
        socket = WebOSSocket(allowInsecureLocalTLS: true)
        socket?.connect(
            host: ip,
            onMessage: { [weak self] (result: Result<URLSessionWebSocketTask.Message, Error>) in
                self?.handleSocketMessage(result)
            },
            completion: { [weak self] (result: Result<Void, Error>) in
                guard let self else { return }
                switch result {
                case .success:
                    self.performRegisterHandshake()
                case .failure(let err):
                    DispatchQueue.main.async {
                        self.isConnected = false
                        self.onDisconnect?()
                        self.lastMessage = "Connect failed: \(err.localizedDescription)"
                        self.completeConnect(false, err.localizedDescription)
                    }
                }
            }
        )
    }

    func disconnect() {
        socket?.close()
        socket = nil
        registered = false
        inputRemotePrimed = false
        inputRemotePriming = false
        queuedButtons.removeAll()
        retryingButtonKey = nil
        failedButtonServices.removeAll()
        pointerSocket?.close()
        pointerSocket = nil
        activeInputRemoteService = nil
        cancelAllPendingRequests(message: "Disconnected")
        if connectCompletion != nil { completeConnect(false, "Disconnected") }
        DispatchQueue.main.async { self.isConnected = false; self.onDisconnect?() }
    }

    private func performRegisterHandshake() {
        DispatchQueue.main.async { self.lastMessage = "Registering…" }
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": manifest
        ]
        if let key = Self.savedClientKey { payload["client-key"] = key }

        let req: [String: Any] = [
            "id": "register-\(UUID().uuidString.prefix(6))",
            "type": "register",
            "payload": payload
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: req, options: []),
              let text = String(data: data, encoding: .utf8) else {
            failEarly("Encode error during register.")
            return
        }
        socket?.send(text, completion: { [weak self] error in
            if let error { self?.failEarly("Register send failed: \(error.localizedDescription)") }
        })
    }

    private var manifest: [String: Any] {
        [
            "manifestVersion": 1,
            "appVersion": "1.0",
            "signed": [
                "created": "2025-01-01",
                "appId": "com.example.lgremote.mvp"
            ],
            "permissions": [
                "LAUNCH","LAUNCH_WEBAPP","APP_TO_APP","CLOSE","TEST_OPEN","TEST_PROTECTED",
                "CONTROL_AUDIO","CONTROL_DISPLAY","CONTROL_INPUT_MEDIA_PLAYBACK","CONTROL_POWER",
                "READ_APP_STATUS","READ_CURRENT_CHANNEL","READ_INPUT_DEVICE_LIST","READ_NETWORK_STATE",
                "READ_TV_CHANNEL_LIST","WRITE_NOTIFICATION_TOAST",
                "CONTROL_MOUSE_AND_KEYBOARD","CONTROL_INPUT_TEXT","CONTROL_INPUT_JOYSTICK",
                "CONTROL_VOLUME","CONTROL_CHANNEL","CONTROL_MEDIA_PLAYBACK","CONTROL_INPUT_MEDIA_RECORDING",
                "CONTROL_INPUT_TV"
            ]
        ]
    }

    // MARK: Message handling

    private func handleSocketMessage(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let msg):
            switch msg {
            case .string(let s):
                DispatchQueue.main.async { self.processJSONMessage(s) }
            case .data:
                break
            @unknown default: break
            }
        case .failure(let err):
            DispatchQueue.main.async {
                self.isConnected = false
                self.registered = false
                self.inputRemotePrimed = false
                self.inputRemotePriming = false
                self.queuedButtons.removeAll()
                self.retryingButtonKey = nil
                self.failedButtonServices.removeAll()
                self.pointerSocket?.close()
                self.pointerSocket = nil
                self.activeInputRemoteService = nil
                self.cancelAllPendingRequests(message: err.localizedDescription)
                self.onDisconnect?()
                self.lastMessage = "Socket error: \(err.localizedDescription)"
            }
        }
    }

    private func processJSONMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else { return }

        let type = dict["type"] as? String ?? ""
        let id = dict["id"] as? String
        let payload = dict["payload"] as? [String: Any]

        switch type {
        case "registered":
            if let key = payload?["client-key"] as? String {
                Self.savedClientKey = key
                self.clientKey = key
            }
            DispatchQueue.main.async {
                let firstRegistration = !self.registered
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                if firstRegistration {
                    self.onConnect?()
                    self.completeConnect(true, "Registered ✓")
                    // proactively attempt pointer mode & input remote
                    self.ensureInputRemoteReady(force: true)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                        self.ensurePointerSocket(force: false)
                    }
                }
            }
            return

        case "response":
            handleResponse(id: id, payload: payload, dict: dict); return
        case "error":
            handleError(id: id, payload: payload, dict: dict); return
        default:
            break
        }

        // Some TVs include client-key in payload with pairingType PROMPT
        if let payload,
           let pairingType = payload["pairingType"] as? String,
           pairingType == "PROMPT",
           let key = payload["client-key"] as? String {
            Self.savedClientKey = key
            self.clientKey = key
            DispatchQueue.main.async {
                let firstRegistration = !self.registered
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                if firstRegistration {
                    self.onConnect?()
                    self.completeConnect(true, "Registered ✓")
                    self.ensurePointerSocket(force: true)
                }
            }
        }
    }

    private func handleResponse(id: String?, payload: [String: Any]?, dict: [String: Any]) {
        guard let id else { return }
        let payloadData = payload ?? [:]
        let returnValue = (payloadData["returnValue"] as? Bool) ?? true

        if returnValue {
            _ = completeRequest(id: id, result: .success(payloadData))
        } else {
            let message = extractErrorMessage(dict: dict, payload: payloadData)
            let error = makeTVError(message, code: -11, payload: payloadData)
            let handled = completeRequest(id: id, result: .failure(error))
            if !handled { DispatchQueue.main.async { self.lastMessage = "Command failed: \(message)" } }
        }
    }

    private func handleError(id: String?, payload: [String: Any]?, dict: [String: Any]) {
        let message = extractErrorMessage(dict: dict, payload: payload)
        var handled = false
        if let id {
            let error = makeTVError(message, code: -12, payload: payload)
            handled = completeRequest(id: id, result: .failure(error))
        }

        if !handled && !registered {
            failEarly("TV error: \(message)")
        } else if !handled {
            DispatchQueue.main.async {
                self.lastMessage = "TV error: \(message)"
            }
        }

        if isGestureTimeout(message) {
            handleGestureTimeout()
        }
    }

    @discardableResult
    private func completeRequest(id: String, result: Result<[String: Any], Error>) -> Bool {
        guard let handler = pendingResponses.removeValue(forKey: id) else { return false }
        DispatchQueue.main.async { handler(result) }
        return true
    }

    private func extractErrorMessage(dict: [String: Any], payload: [String: Any]?) -> String {
        if let payload, let text = payload["errorText"] as? String, !text.isEmpty { return text }
        if let payload, let message = payload["message"] as? String, !message.isEmpty { return message }
        if let error = dict["error"] as? String, !error.isEmpty { return error }
        if let payload, let code = payload["errorCode"] { return "\(code)" }
        return "Unknown error"
    }

    private func makeTVError(_ message: String, code: Int = -10, payload: [String: Any]? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let payload, let errorCode = payload["errorCode"] { userInfo["errorCode"] = errorCode }
        return NSError(domain: "WebOSTV", code: code, userInfo: userInfo)
    }

    private func isGestureTimeout(_ message: String) -> Bool { message.lowercased().contains("gesture gate timed out") }

    private func isServiceMissing(_ message: String, error: Error) -> Bool {
        let lower = message.lowercased()
        if lower.contains("no such service") || lower.contains("service not found") { return true }
        if lower.contains("invalid request") && lower.contains("input") { return true }
        if lower.contains("404") { return true }
        let ns = error as NSError
        if let code = ns.userInfo["errorCode"] as? Int, code == 404 { return true }
        if let codeString = ns.userInfo["errorCode"] as? String, codeString == "404" { return true }
        return false
    }

    private func shouldFallbackToPointer(for error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("internal server error") || lower.contains("500") || lower.contains("application error") { return true }
        let ns = error as NSError
        if let code = ns.userInfo["errorCode"] as? Int, (500...599).contains(code) { return true }
        if (500...599).contains(ns.code) { return true }
        return false
    }

    private func handleGestureTimeout() {
        inputRemotePrimed = false
        ensureInputRemoteReady(force: true)
    }

    // MARK: Utilities

    private func cancelAllPendingRequests(message: String) {
        guard !pendingResponses.isEmpty else { return }
        let handlers = pendingResponses
        pendingResponses.removeAll()
        let error = makeTVError(message, code: -14)
        for handler in handlers.values {
            DispatchQueue.main.async {
                handler(.failure(error))
            }
        }
    }

    private func completeConnect(_ ok: Bool, _ message: String) {
        let comp = connectCompletion
        connectCompletion = nil
        DispatchQueue.main.async {
            comp?(ok, message)
        }
    }

    private func failEarly(_ reason: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.registered = false
            self.inputRemotePrimed = false
            self.inputRemotePriming = false
            self.queuedButtons.removeAll()
            self.retryingButtonKey = nil
            self.failedButtonServices.removeAll()
            self.pointerSocket?.close()
            self.pointerSocket = nil
            self.activeInputRemoteService = nil
            self.launchPointsCache = nil
            self.launchPointsLoading = false
            self.launchPointsWaiters.removeAll()
            self.cancelAllPendingRequests(message: reason)
            self.onDisconnect?()
            self.lastMessage = reason
            self.completeConnect(false, reason)
        }
    }

    // MARK: - Fetch installed apps / launch points

    private var launchPointsCache: [[String: Any]]?
    private var launchPointsLoading = false
    private var launchPointsWaiters: [(Result<[[String: Any]], Error>) -> Void] = []

    func fetchLaunchPoints(completion: @escaping ([ [String: Any] ]) -> Void) {
        if let cache = launchPointsCache { completion(cache); return }
        if launchPointsLoading {
            launchPointsWaiters.append({ res in
                switch res {
                case .success(let arr): completion(arr)
                case .failure(_): completion([]) }
            })
            return
        }
        launchPointsLoading = true
        sendSimple(uri: "ssap://com.webos.applicationManager/listLaunchPoints", payload: [:], retries: 2) { [weak self] result in
            guard let self else { self?.finishLaunchPointsLoad([]); return }
            switch result {
            case .success(let payload):
                let apps = payload["launchPoints"] as? [[String: Any]] ?? payload["apps"] as? [[String: Any]] ?? []
                self.launchPointsCache = apps
                self.finishLaunchPointsLoad(apps)
            case .failure(_):
                self.finishLaunchPointsLoad([])
            }
        }
    }

    private func finishLaunchPointsLoad(_ apps: [[String: Any]]) {
        launchPointsLoading = false
        for waiter in launchPointsWaiters { waiter(.success(apps)) }
        launchPointsWaiters.removeAll()
    }

    // MARK: - fetchMacAddress used by PairTVView

    /// Attempts common URIs and scans the payload for a MAC address.
    func fetchMacAddress(completion: @escaping (String?) -> Void) {
        guard registered else { completion(nil); return }

        let candidates = [
            "ssap://com.webos.service.tv.system/getDeviceInfo",
            "ssap://com.webos.service.system/getDeviceInfo",
            "ssap://system/getDeviceInfo",
            "ssap://com.webos.service.network/getNetworkInfo",
            "ssap://com.webos.service.network/getMacAddress",
            "ssap://com.webos.service.tv.info/getDeviceInfo"
        ]

        func tryNext(_ idx: Int) {
            if idx >= candidates.count {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let uri = candidates[idx]
            sendSimple(uri: uri, payload: [:], retries: 1) { [weak self] (result: Result<[String:Any],Error>) in
                guard let self else { DispatchQueue.main.async { completion(nil) }; return }
                switch result {
                case .success(let payload):
                    if let found = self.extractMacFromPayload(payload) {
                        DispatchQueue.main.async { completion(found) }
                        return
                    }
                    if let found = self.deepSearchForMac(in: payload) {
                        DispatchQueue.main.async { completion(found) }
                        return
                    }
                    tryNext(idx + 1)
                case .failure(_):
                    tryNext(idx + 1)
                }
            }
        }
        tryNext(0)
    }

    // Helpers to find mac-like strings in payloads
    private func extractMacFromPayload(_ payload: [String: Any]) -> String? {
        let keys = ["mac", "macAddress", "ethernetMac", "wifiMac", "bssid", "address"]
        for k in keys {
            if let v = payload[k] as? String, let norm = normalizeMac(v) { return norm }
            if let vnum = payload[k] as? NSNumber {
                if let norm = normalizeMac("\(vnum)") { return norm }
            }
        }
        if let device = payload["device"] as? [String:Any], let m = extractMacFromPayload(device) { return m }
        if let network = payload["network"] as? [String:Any], let m = extractMacFromPayload(network) { return m }
        for (_, v) in payload {
            if let s = v as? String, let norm = normalizeMac(s) { return norm }
        }
        return nil
    }

    private func deepSearchForMac(in any: Any) -> String? {
        if let dict = any as? [String:Any] {
            if let found = extractMacFromPayload(dict) { return found }
            for (_, v) in dict {
                if let found = deepSearchForMac(in: v) { return found }
            }
        } else if let arr = any as? [Any] {
            for item in arr {
                if let found = deepSearchForMac(in: item) { return found }
            }
        } else if let s = any as? String {
            return normalizeMac(s)
        }
        return nil
    }

    private func normalizeMac(_ raw: String) -> String? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let patterns = [
            "([0-9a-f]{2}[:\\-\\.]){5}[0-9a-f]{2}",
            "[0-9a-f]{12}"
        ]
        for pat in patterns {
            if let range = candidate.range(of: pat, options: .regularExpression) {
                let match = String(candidate[range])
                let hexOnly = match.replacingOccurrences(of: "[:\\-\\.]", with: "", options: .regularExpression)
                guard hexOnly.count == 12 else { continue }
                var parts: [String] = []
                var i = hexOnly.startIndex
                for _ in 0..<6 {
                    let j = hexOnly.index(i, offsetBy: 2)
                    parts.append(String(hexOnly[i..<j]).uppercased())
                    i = j
                }
                return parts.joined(separator: ":")
            }
        }
        return nil
    }

    // MARK: - Helper: build pointer socket URLs from payload

    private func pointerSocketURLs(from payload: [String: Any]) -> [URL] {
        var rawEntries: [String] = []

        if let secure = payload["socketPathSecure"] as? String { rawEntries.append(secure) }
        if let path = payload["socketPath"] as? String { rawEntries.append(path) }

        if let list = payload["socketPathList"] as? [String] {
            rawEntries.append(contentsOf: list)
        } else if let nestedList = payload["socketPathList"] as? [[String: Any]] {
            for entry in nestedList {
                if let uri = entry["uri"] as? String { rawEntries.append(uri) }
                if let path = entry["path"] as? String { rawEntries.append(path) }
            }
        }

        if let socketPaths = payload["socketPaths"] as? [String] {
            rawEntries.append(contentsOf: socketPaths)
        }
        if let socket = payload["socket"] as? String {
            rawEntries.append(socket)
        }

        if rawEntries.isEmpty, let address = payload["address"] as? String {
            var ports: [Int] = []
            if let port = payload["port"] as? Int { ports.append(port) }
            else if let ps = payload["port"] as? String, let p = Int(ps) { ports.append(p) }
            if ports.isEmpty { ports = [3001, 3000] }
            for scheme in ["wss", "ws"] {
                for port in ports {
                    rawEntries.append("\(scheme)://\(address):\(port)")
                }
            }
        }

        var urls: [URL] = []
        for entry in rawEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let url = URL(string: trimmed), url.scheme != nil {
                urls.append(url)
            } else {
                var t = trimmed
                if t.hasPrefix("//") { t.removeFirst(2) }
                if !t.hasPrefix("/") { t = "/\(t)" }
                for scheme in ["wss", "ws"] {
                    for port in [3001, 3000] {
                        if let url = URL(string: "\(scheme)://\(ip):\(port)\(t)") {
                            urls.append(url)
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    // MARK: - Input remote register payload

    private func inputRemoteRegisterPayload() -> [String: Any] {
        if let key = self.clientKey, !key.isEmpty {
            return ["client-key": key]
        }
        return [:]
    }

    // MARK: - Utilities: saved keys

    static var savedIPKey: String { "LGRemoteMVP.lastIP" }
    static var savedMACKey: String { "LGRemoteMVP.lastMAC" }

} // end WebOSTV

