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

    private func handleGestureTimeout() {
        inputRemotePrimed = false
        ensureInputRemoteReady(force: true)
    }

    private func ensureInputRemoteReady(force: Bool = false) {
        guard registered else { return }

        if inputRemotePriming { return }
        if !force && inputRemotePrimed { return }

        inputRemotePriming = true
        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/register") { [weak self] result in
            guard let self else { return }
            self.inputRemotePriming = false

            switch result {
            case .success:
                self.inputRemotePrimed = true
                let pending = self.queuedButtons
                self.queuedButtons.removeAll()
                self.retryingButtonKey = nil
                for key in pending {
                    self.sendButton(key: key, allowQueue: false)
                }
            case .failure(let error):
                self.inputRemotePrimed = false
                DispatchQueue.main.async {
                    self.lastMessage = "Input remote error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleCommandFailure(error: Error, key: String, allowQueue: Bool) {
        let message = error.localizedDescription
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

        if allowQueue && !inputRemotePrimed {
            queuedButtons.append(key)
            if queuedButtons.count > 30 {
                queuedButtons.removeFirst(queuedButtons.count - 30)
            }
            ensureInputRemoteReady()
            return
        }

        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/sendButton",
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
        sendSimple(uri: "ssap://system.launcher/launch",
                   payload: ["id": appId])
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
}

