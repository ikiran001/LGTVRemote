// WebOSTV.swift
import Foundation
import Combine

/// High-level session for LG webOS TVs, sitting atop WebOSSocket.
/// - Pre-pings the host for quick feedback
/// - Opens WebSocket (ws/wss raced in WebOSSocket)
/// - Performs REGISTER (pairing) and sets isConnected only after "registered"
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
    private var inputRemotePrimed = false
    private var inputRemotePriming = false
    private var queuedButtons: [String] = []
    private var retryingButtonKey: String?

    private struct InputRemoteService: Equatable {
        let registerURI: String
        let sendButtonURI: String
    }

    private struct PointerService {
        let requestURI: String
    }

    private let inputRemoteButtonCandidates: [InputRemoteService] = [
        InputRemoteService(
            registerURI: "ssap://com.webos.service.tv.inputremote/register",
            sendButtonURI: "ssap://com.webos.service.tv.inputremote/sendButton"
        ),
        InputRemoteService(
            registerURI: "ssap://com.webos.service.remoteinput/register",
            sendButtonURI: "ssap://com.webos.service.remoteinput/sendButton"
        ),
        InputRemoteService(
            registerURI: "ssap://com.webos.service.tvinputremote/register",
            sendButtonURI: "ssap://com.webos.service.tvinputremote/sendButton"
        )
    ]

    private let pointerServiceCandidates: [PointerService] = [
        PointerService(requestURI: "ssap://com.webos.service.tv.inputremote/getPointerInputSocket"),
        PointerService(requestURI: "ssap://com.webos.service.networkinput/getPointerInputSocket")
    ]

    private var activeInputRemoteService: InputRemoteService?
    private var pointerSocket: PointerSocket?
    private struct StreamingAppFallback {
        let alternates: [String]
        let keywordGroups: [[String]]
    }

    private let streamingAppFallbacks: [String: StreamingAppFallback] = {
        let prime = StreamingAppFallback(
            alternates: [
                "amazon-webos", "amazon-webos-us", "primevideo", "com.amazon.amazonvideo.webos",
                "com.amazon.ignition", "amazonprimevideo", "com.webos.app.amazonprimevideo",
                "com.amazon.shoptv.webos", "primevideo-webos", "amazonprimevideo-webos"
            ],
            keywordGroups: [["prime", "video"], ["amazon", "prime"], ["prime"]]
        )
        let hotstar = StreamingAppFallback(
            alternates: ["disneyplus-hotstar", "hotstar", "com.disney.disneyplus-in", "com.star.hotstar", "disney.hotstar"],
            keywordGroups: [["hotstar"], ["disney", "hotstar"], ["disney"]]
        )
        let sonyLiv = StreamingAppFallback(
            alternates: ["sonyliv-webos", "com.sonyliv", "com.sonyliv.sonyliv", "sonyliv", "in.sonyliv.webos"],
            keywordGroups: [["sony", "liv"], ["sonyliv"], ["sony"]]
        )
        let jioCinema = StreamingAppFallback(
            alternates: [
                "com.jio.media.jioplay", "jiocinema", "com.jio.media.ondemand",
                "com.jio.jioplay.tv", "com.jio.jioplay", "com.jio.media.jioplay.tv"
            ],
            keywordGroups: [["jio", "cinema"], ["jiocinema"], ["jio"]]
        )

        var map: [String: StreamingAppFallback] = [
            "amzn.tvarm": prime,
            "com.startv.hotstar.lg": hotstar,
            "com.sonyliv.lg": sonyLiv,
            "com.jio.media.jioplay.tv": jioCinema
        ]

        ["amazon-webos", "amazon-webos-us", "primevideo", "com.amazon.amazonvideo.webos", "com.amazon.ignition", "amazonprimevideo", "com.webos.app.amazonprimevideo", "com.amazon.shoptv.webos", "primevideo-webos", "amazonprimevideo-webos"].forEach {
            map[$0] = prime
        }
        ["disneyplus-hotstar", "hotstar", "com.disney.disneyplus-in", "com.star.hotstar", "disney.hotstar"].forEach {
            map[$0] = hotstar
        }
        ["sonyliv-webos", "com.sonyliv", "com.sonyliv.sonyliv", "sonyliv", "in.sonyliv.webos"].forEach {
            map[$0] = sonyLiv
        }
        ["com.jio.media.jioplay", "jiocinema", "com.jio.media.ondemand", "com.jio.jioplay.tv", "com.jio.jioplay", "com.jio.media.jioplay.tv"].forEach {
            map[$0] = jioCinema
        }

        return map
    }()

    private let streamingAppDisplayNames: [String: String] = [
        "amzn.tvarm": "Prime Video",
        "amazon-webos": "Prime Video",
        "amazon-webos-us": "Prime Video",
        "primevideo": "Prime Video",
        "com.amazon.amazonvideo.webos": "Prime Video",
        "com.amazon.ignition": "Prime Video",
        "amazonprimevideo": "Prime Video",
        "com.webos.app.amazonprimevideo": "Prime Video",
        "com.amazon.shoptv.webos": "Prime Video",
        "primevideo-webos": "Prime Video",
        "amazonprimevideo-webos": "Prime Video",
        "com.startv.hotstar.lg": "Disney+ Hotstar",
        "disneyplus-hotstar": "Disney+ Hotstar",
        "hotstar": "Disney+ Hotstar",
        "com.disney.disneyplus-in": "Disney+ Hotstar",
        "com.star.hotstar": "Disney+ Hotstar",
        "disney.hotstar": "Disney+ Hotstar",
        "com.sonyliv.lg": "Sony LIV",
        "sonyliv-webos": "Sony LIV",
        "com.sonyliv": "Sony LIV",
        "com.sonyliv.sonyliv": "Sony LIV",
        "sonyliv": "Sony LIV",
        "in.sonyliv.webos": "Sony LIV",
        "com.jio.media.jioplay.tv": "JioCinema",
        "com.jio.media.jioplay": "JioCinema",
        "jiocinema": "JioCinema",
        "com.jio.media.ondemand": "JioCinema",
        "com.jio.jioplay.tv": "JioCinema",
        "com.jio.jioplay": "JioCinema"
    ]

    private var launchPointsCache: [[String: Any]]?
    private var launchPointsLoading = false
    private var launchPointsWaiters: [(Result<[[String: Any]], Error>) -> Void] = []

    // Persisted convenience
    static var savedIP: String?  { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP") }
    static var savedMAC: String? { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") }
    private static var savedClientKey: String? {
        get { UserDefaults.standard.string(forKey: "LGRemoteMVP.clientKey") }
        set { UserDefaults.standard.setValue(newValue, forKey: "LGRemoteMVP.clientKey") }
    }

    // MARK: Connect

    /// Connect, but first do a fast ICMP reachability check for nicer UX.
    func connect(ip: String, completion: @escaping (Bool, String) -> Void) {
        self.ip = ip
        connectCompletion = completion
        registered = false
        isConnected = false
        inputRemotePrimed = false
        inputRemotePriming = false
        queuedButtons.removeAll()
        retryingButtonKey = nil
        pointerSocket?.close()
        pointerSocket = nil
        activeInputRemoteService = nil
        launchPointsCache = nil
        launchPointsLoading = false
        launchPointsWaiters.removeAll()
        cancelAllPendingRequests(message: "Previous requests cancelled")
        lastMessage = "Pinging \(ip)…"

        // 1) quick reachability (uses your Ping.swift)
        Ping.isReachable(ip: ip, port: 3000, timeout: 0.7) { [weak self] reachable in
            guard let self else { return }
            if !reachable {
                // Try 3001 as well (some models only respond there)
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
            if !handled {
                DispatchQueue.main.async {
                    self.lastMessage = "Command failed: \(message)"
                }
            }
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
        DispatchQueue.main.async {
            handler(result)
        }
        return true
    }

    private func extractErrorMessage(dict: [String: Any], payload: [String: Any]?) -> String {
        if let payload,
           let text = payload["errorText"] as? String,
           !text.isEmpty {
            return text
        }
        if let payload,
           let message = payload["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let error = dict["error"] as? String,
           !error.isEmpty {
            return error
        }
        if let payload,
           let code = payload["errorCode"] {
            return "\(code)"
        }
        return "Unknown error"
    }

    private func makeTVError(_ message: String, code: Int = -10, payload: [String: Any]? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let payload,
           let errorCode = payload["errorCode"] {
            userInfo["errorCode"] = errorCode
        }
        return NSError(domain: "WebOSTV", code: code, userInfo: userInfo)
    }

    private func isGestureTimeout(_ message: String) -> Bool {
        message.lowercased().contains("gesture gate timed out")
    }

    private func isServiceMissing(_ message: String, error: Error) -> Bool {
        let lower = message.lowercased()
        if lower.contains("no such service") || lower.contains("service not found") {
            return true
        }
        if lower.contains("invalid request") && lower.contains("input") {
            return true
        }
        if lower.contains("404") {
            return true
        }
        let nsError = error as NSError
        if let code = nsError.userInfo["errorCode"] as? Int, code == 404 {
            return true
        }
        if let codeString = nsError.userInfo["errorCode"] as? String,
           codeString == "404" {
            return true
        }
        return false
    }

    private func handleGestureTimeout() {
        inputRemotePrimed = false
        ensureInputRemoteReady(force: true)
    }

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
        guard registered else {
            finalizeInputRemotePrime(error: collectedError)
            return
        }

        guard index < inputRemoteButtonCandidates.count else {
            primePointerService(at: 0, collectedError: collectedError)
            return
        }

        let service = inputRemoteButtonCandidates[index]
        sendSimple(uri: service.registerURI) { [weak self] result in
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
                self.primeButtonService(at: index + 1, collectedError: error)
            }
        }
    }

    private func primePointerService(at index: Int, collectedError: Error?) {
        guard registered else {
            finalizeInputRemotePrime(error: collectedError)
            return
        }

        guard !pointerServiceCandidates.isEmpty else {
            finalizeInputRemotePrime(error: collectedError)
            return
        }

        guard index < pointerServiceCandidates.count else {
            finalizeInputRemotePrime(error: collectedError)
            return
        }

        let candidate = pointerServiceCandidates[index]
        sendSimple(uri: candidate.requestURI) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                let urls = self.pointerSocketURLs(from: payload)
                guard !urls.isEmpty else {
                    self.primePointerService(at: index + 1, collectedError: collectedError)
                    return
                }
                self.openPointerSocket(with: urls) { success, error in
                    if success {
                        self.activeInputRemoteService = nil
                        self.inputRemotePrimed = true
                        self.inputRemotePriming = false
                        self.lastMessage = "Input remote ready (pointer)"
                        self.flushQueuedButtons()
                    } else {
                        self.pointerSocket = nil
                        let aggregatedError = error ?? collectedError
                        self.primePointerService(at: index + 1, collectedError: aggregatedError)
                    }
                }
            case .failure(let error):
                self.primePointerService(at: index + 1, collectedError: error)
            }
        }
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

    private func flushQueuedButtons() {
        guard !queuedButtons.isEmpty else { return }
        let pending = queuedButtons
        queuedButtons.removeAll()
        retryingButtonKey = nil
        for key in pending {
            sendButton(key: key, allowQueue: false)
        }
    }

    private func openPointerSocket(with urls: [URL], completion: @escaping (Bool, Error?) -> Void) {
        guard !urls.isEmpty else {
            completion(false, makeTVError("Pointer socket path missing", code: -15))
            return
        }

        let socket = PointerSocket(host: ip, allowInsecureLocalTLS: true)
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
                self.ensureInputRemoteReady(force: true)
            }
        }

        socket.connect(urls: urls) { [weak self, weak socket] success, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if !success, let socket, self.pointerSocket === socket {
                    self.pointerSocket = nil
                }
                completion(success, error)
            }
        }
    }

    private func pointerSocketURLs(from payload: [String: Any]) -> [URL] {
        var rawEntries: [String] = []

        if let secure = payload["socketPathSecure"] as? String { rawEntries.append(secure) }
        if let path = payload["socketPath"] as? String { rawEntries.append(path) }
        if let list = payload["socketPathList"] as? [String] {
            rawEntries.append(contentsOf: list)
        } else if let nestedList = payload["socketPathList"] as? [[String: Any]] {
            for entry in nestedList {
                if let uri = entry["uri"] as? String {
                    rawEntries.append(uri)
                }
                if let path = entry["path"] as? String {
                    rawEntries.append(path)
                }
            }
        }
        if let socketPaths = payload["socketPaths"] as? [String] {
            rawEntries.append(contentsOf: socketPaths)
        }
        if let socket = payload["socket"] as? String {
            rawEntries.append(socket)
        }

        var urls: [URL] = []
        for entry in rawEntries {
            urls.append(contentsOf: buildPointerURLs(from: entry))
        }

        if urls.isEmpty, let address = payload["address"] as? String {
            var ports: [Int] = []
            if let port = payload["port"] as? Int {
                ports.append(port)
            } else if let portString = payload["port"] as? String, let port = Int(portString) {
                ports.append(port)
            }
            if ports.isEmpty { ports = [3001, 3000] }
            for scheme in ["wss", "ws"] {
                for port in ports {
                    if let url = URL(string: "\(scheme)://\(address):\(port)") {
                        urls.append(url)
                    }
                }
            }
        }

        return dedupe(urls)
    }

    private func buildPointerURLs(from raw: String) -> [URL] {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var urls: [URL] = []

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "ws", "wss":
                urls.append(url)
                if let toggled = toggleWSScheme(for: url) {
                    urls.append(toggled)
                }
                return dedupe(urls)
            case "http", "https":
                if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.scheme = (scheme == "http") ? "ws" : "wss"
                    if let wsURL = components.url {
                        urls.append(wsURL)
                        if let toggled = toggleWSScheme(for: wsURL) {
                            urls.append(toggled)
                        }
                        return dedupe(urls)
                    }
                }
            default:
                break
            }
        }

        if trimmed.hasPrefix("//") {
            trimmed.removeFirst(2)
        }

        if !trimmed.hasPrefix("/") {
            trimmed = "/\(trimmed)"
        }

        for scheme in ["wss", "ws"] {
            for port in [3001, 3000] {
                if let url = URL(string: "\(scheme)://\(ip):\(port)\(trimmed)") {
                    urls.append(url)
                }
            }
        }

        return dedupe(urls)
    }

    private func toggleWSScheme(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme {
        case "ws":
            components.scheme = "wss"
        case "wss":
            components.scheme = "ws"
        default:
            return nil
        }
        return components.url
    }

    private func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    private func handleCommandFailure(error: Error, key: String, allowQueue: Bool) {
        let message = error.localizedDescription
        if allowQueue && isServiceMissing(message, error: error) {
            if retryingButtonKey != key {
                retryingButtonKey = key
            }
            if allowQueue {
                queuedButtons.removeAll { $0 == key }
                queuedButtons.insert(key, at: 0)
                if queuedButtons.count > 30 {
                    queuedButtons = Array(queuedButtons.prefix(30))
                }
            }
            activeInputRemoteService = nil
            pointerSocket?.close()
            pointerSocket = nil
            inputRemotePrimed = false
            lastMessage = "Input remote service unavailable, retrying…"
            ensureInputRemoteReady(force: true)
            return
        }
        if allowQueue && isGestureTimeout(message) {
            if retryingButtonKey != key {
                retryingButtonKey = key
                queuedButtons.insert(key, at: 0)
            }
            inputRemotePrimed = false
            ensureInputRemoteReady(force: true)
            return
        }

        if retryingButtonKey == key {
            retryingButtonKey = nil
        }

        DispatchQueue.main.async {
            self.lastMessage = "Command failed: \(message)"
        }
    }

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

    private func openSocketAndRegister() {
        DispatchQueue.main.async { self.lastMessage = "Opening socket…" }
        socket = WebOSSocket(allowInsecureLocalTLS: true)
        socket?.connect(
            host: ip,
            onMessage: { [weak self] result in
                self?.handleSocketMessage(result)
            },
            completion: { [weak self] result in
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
        pointerSocket?.close()
        pointerSocket = nil
        activeInputRemoteService = nil
        launchPointsCache = nil
        launchPointsLoading = false
        launchPointsWaiters.removeAll()
        cancelAllPendingRequests(message: "Disconnected")
        if connectCompletion != nil {
            completeConnect(false, "Disconnected")
        }
        DispatchQueue.main.async {
            self.isConnected = false
            self.onDisconnect?()
        }
    }

    // MARK: Pairing / Register

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

    private func handleSocketMessage(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let msg):
            switch msg {
            case .string(let s):
                DispatchQueue.main.async { self.lastMessage = s }
                self.processJSONMessage(s)
            case .data(let d):
                DispatchQueue.main.async { self.lastMessage = "binary(\(d.count))" }
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
            }
            DispatchQueue.main.async {
                let firstRegistration = !self.registered
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                if firstRegistration {
                    self.onConnect?()
                    self.completeConnect(true, "Registered ✓")
                    self.ensureInputRemoteReady(force: true)
                }
            }
            return

        case "response":
            handleResponse(id: id, payload: payload, dict: dict)
            return

        case "error":
            handleError(id: id, payload: payload, dict: dict)
            return

        default:
            break
        }

        if let payload,
           let pairingType = payload["pairingType"] as? String,
           pairingType == "PROMPT",
           let key = payload["client-key"] as? String {
            Self.savedClientKey = key
            DispatchQueue.main.async {
                let firstRegistration = !self.registered
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                if firstRegistration {
                    self.onConnect?()
                    self.completeConnect(true, "Registered ✓")
                    self.ensureInputRemoteReady(force: true)
                }
            }
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

    // MARK: Sending helpers

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

    func sendSimple(uri: String,
                    payload: [String: Any] = [:],
                    completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard registered else {
            if let completion {
                completion(.failure(makeTVError("TV not registered yet", code: -3)))
            }
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

        send(req) { [weak self] error in
            guard let self else { return }
            if let error,
               let handler = self.pendingResponses.removeValue(forKey: requestId) {
                DispatchQueue.main.async {
                    handler(.failure(error))
                }
            }
        }
    }

    func sendButton(key: String) {
        sendButton(key: key, allowQueue: true)
    }

    private func sendButton(key: String, allowQueue: Bool) {
        guard registered else { return }

        if let pointer = pointerSocket, pointer.isReady {
            pointer.sendButton(key)
            if retryingButtonKey == key {
                retryingButtonKey = nil
            }
            return
        }

        guard inputRemotePrimed, let service = activeInputRemoteService else {
            if allowQueue {
                queuedButtons.append(key)
                if queuedButtons.count > 30 {
                    queuedButtons.removeFirst(queuedButtons.count - 30)
                }
                ensureInputRemoteReady()
            }
            return
        }

        sendSimple(uri: service.sendButtonURI,
                   payload: ["name": key]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.retryingButtonKey == key {
                    self.retryingButtonKey = nil
                }
            case .failure(let error):
                self.handleCommandFailure(error: error, key: key, allowQueue: allowQueue)
            }
        }
    }

    func launchStreamingApp(_ appId: String) {
        attemptLaunch(appId: appId, originalKey: appId, tried: [])
    }

    private func attemptLaunch(appId: String, originalKey: String, tried: Set<String>) {
        DispatchQueue.main.async {
            self.lastMessage = "Launching \(self.displayName(for: appId))…"
        }
        sendSimple(uri: "ssap://system.launcher/launch",
                   payload: ["id": appId]) { [weak self] result in
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
        if lower.contains("no such app") || lower.contains("no such application") || lower.contains("not installed") || lower.contains("no such service") || lower.contains("not exist") {
            return true
        }
        if lower.contains("internal server error") ||
            lower.contains("internal error") ||
            lower.contains("application error") ||
            lower.contains("500") ||
            lower.contains("404") {
            return true
        }
        let nsError = error as NSError
        if (400...599).contains(nsError.code) {
            return true
        }
        if let code = nsError.userInfo["errorCode"] as? Int, [404, 500].contains(code) {
            return true
        }
        if let codeNumber = nsError.userInfo["errorCode"] as? NSNumber,
           (400...599).contains(codeNumber.intValue) {
            return true
        }
        if let codeString = nsError.userInfo["errorCode"] as? String,
           let numeric = Int(codeString.trimmingCharacters(in: .whitespaces)),
           (400...599).contains(numeric) {
            return true
        }
        return false
    }

    private func resolveNextAppId(originalKey: String, tried: Set<String>, completion: @escaping (String?) -> Void) {
        let key = originalKey.lowercased()
        guard let fallback = streamingAppFallbacks[key] else {
            completion(nil)
            return
        }

        if let next = fallback.alternates.first(where: { !tried.contains($0.lowercased()) }) {
            completion(next)
            return
        }

        guard !fallback.keywordGroups.isEmpty else {
            completion(nil)
            return
        }

        fetchLaunchPoints { [weak self] result in
            guard let self else {
                completion(nil)
                return
            }
            switch result {
            case .success(let points):
                let match = self.findAppId(in: points, matching: fallback.keywordGroups, excluding: tried)
                completion(match)
            case .failure:
                completion(nil)
            }
        }
    }

    private func fetchLaunchPoints(_ completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        if let cache = launchPointsCache {
            completion(.success(cache))
            return
        }

        launchPointsWaiters.append(completion)
        guard !launchPointsLoading else { return }

        launchPointsLoading = true
        sendSimple(uri: "ssap://com.webos.applicationManager/listLaunchPoints") { [weak self] result in
            guard let self else { return }
            self.launchPointsLoading = false
            switch result {
            case .success(let payload):
                let points = payload["launchPoints"] as? [[String: Any]] ?? []
                self.launchPointsCache = points
                self.launchPointsWaiters.forEach { $0(.success(points)) }
            case .failure(let error):
                self.launchPointsWaiters.forEach { $0(.failure(error)) }
            }
            self.launchPointsWaiters.removeAll()
        }
    }

    private func findAppId(in launchPoints: [[String: Any]],
                           matching keywordGroups: [[String]],
                           excluding tried: Set<String>) -> String? {
        let normalizedGroups = keywordGroups.map { group in group.map { $0.lowercased() } }
        let flatKeywords = Set(normalizedGroups.flatMap { $0 })
        let entries: [(id: String, title: String)] = launchPoints.compactMap { point in
            if let id = point["id"] as? String {
                let title = (point["title"] as? String ?? "").lowercased()
                return (id, title)
            }
            if let appId = point["appId"] as? String {
                let title = (point["title"] as? String ?? "").lowercased()
                return (appId, title)
            }
            return nil
        }

        var bestMatch: (id: String, score: Int)?
        for entry in entries {
            if tried.contains(entry.id.lowercased()) { continue }
            let idLower = entry.id.lowercased()
            var score = 0
            for group in normalizedGroups where !group.isEmpty {
                let allMatch = group.allSatisfy { keyword in
                    entry.title.contains(keyword) || idLower.contains(keyword)
                }
                if allMatch {
                    score += 100 + group.count
                } else {
                    let partialCount = group.reduce(0) { partial, keyword in
                        partial + (entry.title.contains(keyword) || idLower.contains(keyword) ? 1 : 0)
                    }
                    score += partialCount
                }
            }
            if score == 0 && !flatKeywords.isEmpty {
                let partialFlat = flatKeywords.reduce(0) { partial, keyword in
                    partial + (entry.title.contains(keyword) || idLower.contains(keyword) ? 1 : 0)
                }
                score += partialFlat
            }
            if score > 0 {
                if let best = bestMatch {
                    if score > best.score {
                        bestMatch = (entry.id, score)
                    }
                } else {
                    bestMatch = (entry.id, score)
                }
            }
        }
        return bestMatch?.id
    }

    // For PairTVView compatibility
    func fetchMacAddress(_ completion: @escaping (String?) -> Void) {
        guard registered else { completion(nil); return }
        let req: [String: Any] = [
            "id": nextRequestId("sysinfo"),
            "type": "request",
            "uri": "luna://com.webos.service.tv.systemproperty/getSystemInfo",
            "payload": ["keys": ["wifiMacAddress", "wiredMacAddress"]]
        ]
        send(req) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion(nil) }
        }
    }

    private func completeConnect(_ success: Bool, _ message: String) {
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        if Thread.isMainThread {
            completion(success, message)
        } else {
            DispatchQueue.main.async {
                completion(success, message)
            }
        }
    }

    private final class PointerSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {

        private typealias SocketCandidate = (url: URL, protocols: [String])

        // Offer at most one subprotocol name per handshake. Some TVs echo every value
        // back in separate headers, which makes Apple's WebSocket stack reject the
        // handshake when multiple values are present.
        private static let protocolPreference: [[String]] = [
            ["sec-websocket-protocol"],
            ["lgtv"],
            []
        ]

        private let allowInsecureLocalTLS: Bool
        private let host: String
        private var session: URLSession!
        private var candidateQueue: [SocketCandidate] = []
        private var currentCandidate: SocketCandidate?
        private var currentTask: URLSessionWebSocketTask?
        private var completion: ((Bool, Error?) -> Void)?
        private var sendQueue: [String] = []
        private var isOpen = false
        private var lastError: Error?

        var onDisconnect: ((Error?) -> Void)?

        var isReady: Bool { isOpen }

        init(host: String, allowInsecureLocalTLS: Bool) {
            self.host = host
            self.allowInsecureLocalTLS = allowInsecureLocalTLS
            super.init()
            let configuration = URLSessionConfiguration.default
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        }

        func connect(urls: [URL], completion: @escaping (Bool, Error?) -> Void) {
            self.completion = completion
            candidateQueue = buildCandidateQueue(from: urls)
            currentCandidate = nil
            lastError = nil
            sendQueue.removeAll()
            isOpen = false
            attemptNextCandidate()
        }

        func sendButton(_ key: String) {
            let payload: [String: String] = ["type": "button", "name": key]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let text = String(data: data, encoding: .utf8) else { return }

            sendOrQueue(text)
        }

        func close() {
            if completion != nil {
                let error = NSError(domain: "PointerSocket",
                                    code: -999,
                                    userInfo: [NSLocalizedDescriptionKey: "Pointer socket cancelled"])
                complete(success: false, error: error)
            }
            onDisconnect = nil
            candidateQueue.removeAll()
            currentCandidate = nil
            lastError = nil
            isOpen = false
            sendQueue.removeAll()
            currentTask?.cancel(with: .goingAway, reason: nil)
            currentTask = nil
            session.invalidateAndCancel()
        }

        private func attemptNextCandidate() {
            currentTask?.cancel(with: .goingAway, reason: nil)
            currentTask = nil
            isOpen = false

            guard !candidateQueue.isEmpty else {
                let failureError: Error
                if let lastError {
                    failureError = lastError
                } else {
                    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "Unable to open pointer socket"]
                    if let candidate = currentCandidate {
                        userInfo["candidateURL"] = candidate.url.absoluteString
                        if !candidate.protocols.isEmpty {
                            userInfo["protocols"] = candidate.protocols.joined(separator: ",")
                        }
                    }
                    failureError = NSError(domain: "PointerSocket", code: -1, userInfo: userInfo)
                }
                complete(success: false, error: failureError)
                return
            }

            let candidate = candidateQueue.removeFirst()
            currentCandidate = candidate
            lastError = nil
            let task: URLSessionWebSocketTask
            if candidate.protocols.isEmpty {
                task = session.webSocketTask(with: candidate.url)
            } else {
                task = session.webSocketTask(with: candidate.url, protocols: candidate.protocols)
            }
            currentTask = task
            task.resume()
            receiveLoop(task)
        }

        private func receiveLoop(_ task: URLSessionWebSocketTask) {
            task.receive { [weak self] result in
                guard let self else { return }
                guard task === self.currentTask else { return }
                switch result {
                case .success:
                    self.receiveLoop(task)
                case .failure(let error):
                    if self.isOpen {
                        self.handleDisconnect(error: error)
                    } else {
                        self.lastError = error
                        self.attemptNextCandidate()
                    }
                }
            }
        }

        private func flushQueuedSends() {
            guard isOpen, let task = currentTask else { return }
            for text in sendQueue {
                task.send(.string(text)) { [weak self] error in
                    guard let self, let error else { return }
                    DispatchQueue.main.async { self.handleDisconnect(error: error) }
                }
            }
            sendQueue.removeAll()
        }

        private func sendOrQueue(_ text: String) {
            guard isOpen, let task = currentTask else {
                sendQueue.append(text)
                return
            }
            task.send(.string(text)) { [weak self] error in
                guard let self, let error else { return }
                DispatchQueue.main.async { self.handleDisconnect(error: error) }
            }
        }

        private func handleDisconnect(error: Error?) {
            currentTask?.cancel(with: .goingAway, reason: nil)
            currentTask = nil
            sendQueue.removeAll()
            if isOpen {
                isOpen = false
                currentCandidate = nil
                let callback = onDisconnect
                if let callback {
                    callback(error)
                }
            } else {
                lastError = error
                attemptNextCandidate()
            }
        }

        private func complete(success: Bool, error: Error?) {
            guard let completion else { return }
            self.completion = nil
            if success {
                candidateQueue.removeAll()
                currentCandidate = nil
            }
            completion(success, error)
        }

        // MARK: URLSessionWebSocketDelegate

        func urlSession(_ session: URLSession,
                        webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol protocol: String?) {
            guard webSocketTask === currentTask else { return }
            isOpen = true
            lastError = nil
            flushQueuedSends()
            complete(success: true, error: nil)
        }

        func urlSession(_ session: URLSession,
                        webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                        reason: Data?) {
            guard webSocketTask === currentTask else { return }
            let error = NSError(domain: "PointerSocket",
                                code: Int(closeCode.rawValue),
                                userInfo: [NSLocalizedDescriptionKey: "Pointer socket closed (\(closeCode.rawValue))"])
            handleDisconnect(error: error)
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error, task === currentTask else { return }
            handleDisconnect(error: error)
        }

        private func buildCandidateQueue(from urls: [URL]) -> [SocketCandidate] {
            guard !urls.isEmpty else { return [] }

            let prioritized = prioritize(urls: urls)
            var raw: [SocketCandidate] = []
            for url in prioritized {
                for protocols in PointerSocket.protocolPreference {
                    raw.append((url, protocols))
                }
            }
            return dedupeCandidates(raw)
        }

        private func prioritize(urls: [URL]) -> [URL] {
            urls.sorted { lhs, rhs in
                schemePriority(lhs) < schemePriority(rhs)
            }
        }

        private func schemePriority(_ url: URL) -> Int {
            switch url.scheme?.lowercased() {
            case "wss": return 0
            case "ws": return 1
            case "https": return 2
            case "http": return 3
            default: return 4
            }
        }

        private func dedupeCandidates(_ candidates: [SocketCandidate]) -> [SocketCandidate] {
            var seen = Set<String>()
            var result: [SocketCandidate] = []
            for candidate in candidates {
                let protoKey = candidate.protocols.joined(separator: ",")
                let key = candidate.url.absoluteString + "|" + protoKey
                if seen.insert(key).inserted {
                    result.append(candidate)
                }
            }
            return result
        }

        // MARK: URLSessionDelegate

        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let challengeHost = challenge.protectionSpace.host.isEmpty ? host : challenge.protectionSpace.host
            guard allowInsecureLocalTLS,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  isLocalRFC1918(host: challengeHost) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        private func isLocalRFC1918(host: String) -> Bool {
            if host.hasPrefix("10.") { return true }
            if host.hasPrefix("192.168.") { return true }
            if host.hasPrefix("172.") {
                let parts = host.split(separator: ".")
                if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                    return true
                }
            }
            return false
        }
    }
}

