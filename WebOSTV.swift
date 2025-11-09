// WebOSTV.swift
import Foundation
import Combine

/// High-level session for LG webOS TVs, sitting atop WebOSSocket.
/// - Opens a WebSocket (ws/wss raced inside WebOSSocket)
/// - Performs the **register** handshake (pairing). We mark `isConnected` only after "registered".
/// - Persists and reuses `client-key` so you won't be prompted again.
final class WebOSTV: ObservableObject {

    // MARK: Published state for UI
    @Published private(set) var isConnected = false     // true only after "registered"
    @Published private(set) var ip: String = ""
    @Published private(set) var lastMessage: String = ""

    // Optional callbacks
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    // MARK: Internals
    private var socket: WebOSSocket?
    private var nextId = 1
    private var registered = false
    private var connectCompletion: ((Bool, String) -> Void)?
    private var pendingResponses: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var registerRequestId: String?
    private var retriedWithoutClientKey = false
    private var inputRemotePrimed = false
    private var inputRemotePriming = false
    private var inputRemoteWaiters: [(Bool) -> Void] = []
    private let inputRemoteName = "LG Remote Neo"

    // Persisted convenience
    static var savedIP: String?  { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP") }
    static var savedMAC: String? { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") }
    private static var savedClientKey: String? {
        get { UserDefaults.standard.string(forKey: "LGRemoteMVP.clientKey") }
        set { UserDefaults.standard.setValue(newValue, forKey: "LGRemoteMVP.clientKey") }
    }

    // MARK: Connect / Disconnect

    func connect(ip: String, completion: @escaping (Bool, String) -> Void) {
        self.ip = ip
        connectCompletion = completion
        retriedWithoutClientKey = false
        prepareForConnectionAttempt(andNotify: true)
        startSocketConnection()
    }

    func disconnect() {
        socket?.close()
        socket = nil
        registered = false
        registerRequestId = nil
        resetInputRemoteState(andNotify: true)
        cancelPendingRequests(with: NSError(domain: "WebOSTV", code: -11,
                                            userInfo: [NSLocalizedDescriptionKey: "Connection closed"]))
        DispatchQueue.main.async {
            self.isConnected = false
            self.onDisconnect?()
            self.completeConnect(success: false, message: "Disconnected")
        }
    }

    // MARK: Pairing / Register

    private func prepareForConnectionAttempt(andNotify notify: Bool) {
        socket?.close()
        socket = nil
        registered = false
        isConnected = false
        registerRequestId = nil

        cancelPendingRequests(with: NSError(domain: "WebOSTV", code: -10,
                                            userInfo: [NSLocalizedDescriptionKey: "New connection started"]))
        resetInputRemoteState(andNotify: notify)
    }

    private func startSocketConnection() {
        socket?.close()
        let newSocket = WebOSSocket(allowInsecureLocalTLS: true)
        socket = newSocket

        newSocket.connect(host: ip,
                          onMessage: { [weak self] result in
                              self?.handleSocketMessage(result)
                          }, completion: { [weak self] result in
                              guard let self else { return }
                              switch result {
                              case .success:
                                  // Socket is open; now we must REGISTER before we can send commands.
                                  self.performRegisterHandshake()
                              case .failure(let err):
                                  self.handleSocketConnectFailure(err)
                              }
                          })
    }

    private func handleSocketConnectFailure(_ error: Error) {
        if shouldRetryWithoutClientKey(after: error) {
            retryConnectionWithoutClientKey(after: error)
            return
        }

        DispatchQueue.main.async {
            self.isConnected = false
            self.onDisconnect?()
            self.lastMessage = "Connection failed: \(error.localizedDescription)"
            self.completeConnect(success: false, message: error.localizedDescription)
        }
    }

    private func shouldRetryWithoutClientKey(after error: Error) -> Bool {
        guard !registered,
              !retriedWithoutClientKey,
              registerRequestId != nil,
              Self.savedClientKey != nil else {
            return false
        }

        let nsError = error as NSError

        if nsError.domain == URLError.errorDomain,
           nsError.code == URLError.networkConnectionLost.rawValue {
            return true
        }

        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ECONNRESET.rawValue) {
            return true
        }

        return false
    }

    private func retryConnectionWithoutClientKey(after error: Error) {
        Self.savedClientKey = nil
        retriedWithoutClientKey = true
        prepareForConnectionAttempt(andNotify: false)

        DispatchQueue.main.async {
            self.lastMessage = "TV rejected the saved access key. Approve the new pairing request on your TV."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.startSocketConnection()
        }
    }

    private func performRegisterHandshake() {
        // If we have a client-key, send it to avoid the prompt.
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": manifest // permissions we request
        ]
        if let key = Self.savedClientKey {
            payload["client-key"] = key
        }

        let registerId = "register-\(UUID().uuidString.prefix(6))"
        registerRequestId = registerId

        let req: [String: Any] = [
            "id": registerId,
            "type": "register",
            "payload": payload
        ]
        // Send raw; don't guard on isConnected yet—we're not "connected" until registered.
        guard let data = try? JSONSerialization.data(withJSONObject: req, options: []),
              let text = String(data: data, encoding: .utf8) else {
            failEarly("Encode error during register.")
            return
        }
        socket?.send(text, completion: { [weak self] error in
            if let error { self?.failEarly("Register send failed: \(error.localizedDescription)") }
        })
    }

    /// Minimal manifest: request only what we need for remote + app launch.
    private var manifest: [String: Any] {
        [
            "manifestVersion": 1,
            "appVersion": "1.0",
            "signed": [
                "created": "2025-01-01",
                "appId": "com.example.lgremote.mvp"
            ],
            "permissions": [
                "LAUNCH",
                "LAUNCH_WEBAPP",
                "APP_TO_APP",
                "CLOSE",
                "TEST_OPEN",
                "TEST_PROTECTED",
                "CONTROL_AUDIO",
                "CONTROL_DISPLAY",
                "CONTROL_INPUT_MEDIA_PLAYBACK",
                "CONTROL_POWER",
                "READ_APP_STATUS",
                "READ_CURRENT_CHANNEL",
                "READ_INPUT_DEVICE_LIST",
                "READ_NETWORK_STATE",
                "READ_TV_CHANNEL_LIST",
                "WRITE_NOTIFICATION_TOAST",
                "CONTROL_MOUSE_AND_KEYBOARD",
                "CONTROL_INPUT_TEXT",
                "CONTROL_INPUT_JOYSTICK",
                "CONTROL_VOLUME",
                "CONTROL_CHANNEL",
                "CONTROL_MEDIA_PLAYBACK",
                "CONTROL_INPUT_MEDIA_RECORDING",
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
                self.resetInputRemoteState(andNotify: true)
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
        let payload = (dict["payload"] as? [String: Any]) ?? [:]
        let id = dict["id"] as? String

        if type == "registered" {
            if let key = payload["client-key"] as? String {
                Self.savedClientKey = key
            }
            DispatchQueue.main.async {
                self.registerRequestId = nil
                self.retriedWithoutClientKey = false
                self.registered = true
                self.isConnected = true
                self.onConnect?()
                self.completeConnect(success: true, message: "Connected")
                self.primeInputRemoteIfNeeded()
            }
            return
        }

        if type == "response", let id, id == registerRequestId {
            if let returnValue = payload["returnValue"] as? Bool, returnValue == false {
                let message = (payload["errorText"] as? String)
                    ?? (payload["errorMessage"] as? String)
                    ?? (payload["error"] as? String)
                    ?? "TV returned failure"
                handleRegisterFailure(payload: payload, message: message)
            } else if let pairingType = (payload["pairingType"] as? String)?.uppercased(), pairingType == "PROMPT" {
                DispatchQueue.main.async {
                    self.lastMessage = "Approve the pairing request on your TV to finish connecting."
                }
            }
            return
        }

        if type == "error" {
            let message = (dict["error"] as? String)
                ?? (payload["errorText"] as? String)
                ?? (payload["errorMessage"] as? String)
                ?? (payload["error"] as? String)
                ?? "Unknown register error"

            if let id, id == registerRequestId {
                handleRegisterFailure(payload: payload, message: message)
                return
            }

            failEarly("TV error: \(message)")
            if let id {
                let error = NSError(domain: "WebOSTV", code: -5,
                                    userInfo: [NSLocalizedDescriptionKey: message])
                resolvePending(for: id, with: .failure(error))
            }
            return
        }

        if type == "response", let id = id {
            if let returnValue = payload["returnValue"] as? Bool, returnValue == false {
                let message = (payload["errorText"] as? String)
                    ?? (payload["errorMessage"] as? String)
                    ?? (payload["error"] as? String)
                    ?? "TV returned failure"
                resolvePending(for: id, with: .failure(NSError(domain: "WebOSTV", code: -6,
                                                                userInfo: [NSLocalizedDescriptionKey: message])))
            } else {
                resolvePending(for: id, with: .success(payload))
            }
        }
    }

    private func handleRegisterFailure(payload: [String: Any], message: String) {
        if let _ = Self.savedClientKey, !retriedWithoutClientKey {
            let authRelated = isClientKeyAuthError(payload: payload, message: message)

            Self.savedClientKey = nil
            retriedWithoutClientKey = true
            registerRequestId = nil

            DispatchQueue.main.async {
                self.lastMessage = authRelated
                    ? "TV rejected the saved access key. Approve the new pairing prompt on your TV."
                    : "Pairing failed with the saved key. Trying again—approve the pairing request on your TV."
            }

            performRegisterHandshake()
            return
        }
        failEarly("TV error: \(message)")
    }

    private func isClientKeyAuthError(payload: [String: Any], message: String) -> Bool {
        var codes: [Int] = []
        let nestedPayload = payload["payload"] as? [String: Any]

        let codeCandidates: [Any?] = [
            payload["errorCode"],
            payload["code"],
            payload["status"],
            payload["statusCode"],
            nestedPayload?["errorCode"],
            nestedPayload?["code"]
        ]

        for candidate in codeCandidates {
            if let code = Self.parseErrorCode(candidate) {
                codes.append(code)
            }
        }

        if codes.contains(where: { [401, 403, -401, -403, -1000, -107, -105].contains($0) }) {
            return true
        }

        var strings: [String] = [
            message,
            payload["errorText"] as? String ?? "",
            payload["errorMessage"] as? String ?? "",
            payload["error"] as? String ?? "",
            payload["message"] as? String ?? ""
        ]

        if let nested = nestedPayload {
            strings.append(contentsOf: [
                nested["errorText"] as? String ?? "",
                nested["errorMessage"] as? String ?? "",
                nested["error"] as? String ?? "",
                nested["message"] as? String ?? ""
            ])
        }

        let keywords = [
            "client key",
            "client-key",
            "unauthorized",
            "forbidden",
            "denied",
            "not registered",
            "not paired",
            "authentication",
            "auth failure",
            "invalid key",
            "invalid client",
            "pairing key"
        ]

        for text in strings {
            let lower = text.lowercased()
            if keywords.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func parseErrorCode(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) {
                return int
            }
            if trimmed.lowercased().hasPrefix("0x"),
               let int = Int(trimmed.dropFirst(2), radix: 16) {
                return int
            }
            return nil
        default:
            return nil
        }
    }

    private func failEarly(_ reason: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.registered = false
            self.registerRequestId = nil
            self.resetInputRemoteState(andNotify: true)
            self.onDisconnect?()
            self.lastMessage = reason
            self.cancelPendingRequests(with: NSError(domain: "WebOSTV", code: -12,
                                                     userInfo: [NSLocalizedDescriptionKey: reason]))
            self.completeConnect(success: false, message: reason)
        }
    }

    private func completeConnect(success: Bool, message: String) {
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(success, message)
    }

    private func resolvePending(for id: String, with result: Result<[String: Any], Error>) {
        guard let handler = pendingResponses.removeValue(forKey: id) else { return }
        handler(result)
    }

    private func cancelPendingRequests(with error: Error) {
        guard !pendingResponses.isEmpty else { return }
        let handlers = pendingResponses
        pendingResponses.removeAll()
        handlers.values.forEach { $0(.failure(error)) }
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

    /// Generic request for ssap:// URIs
    func sendSimple(uri: String, payload: [String: Any] = [:], completion: ((Error?) -> Void)? = nil) {
        guard registered else {
            completion?(NSError(domain: "WebOSTV", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "TV not registered yet"]))
            return
        }
        let requestId = nextRequestId("req")
        let req: [String: Any] = [
            "id": requestId,
            "type": "request",
            "uri": uri,
            "payload": payload
        ]
        if let handler = completion {
            pendingResponses[requestId] = { result in
                switch result {
                case .success:
                    handler(nil)
                case .failure(let error):
                    handler(error)
                }
            }
            send(req) { error in
                if let error {
                    self.resolvePending(for: requestId, with: .failure(error))
                }
            }
        } else {
            send(req)
        }
    }

    /// Remote key
    func sendButton(key: String) {
        guard registered else {
            DispatchQueue.main.async {
                self.lastMessage = "Cannot send \(key) – TV not connected."
            }
            return
        }

        if inputRemotePrimed {
            sendButtonCommand(key)
            return
        }

        primeInputRemoteIfNeeded { [weak self] ready in
            guard let self else { return }
            if ready {
                self.sendButtonCommand(key)
            } else {
                DispatchQueue.main.async {
                    self.lastMessage = "Command \(key) aborted – remote channel unavailable."
                }
            }
        }
    }

    /// Launch app by ID
    func launchStreamingApp(_ appId: String) {
        sendSimple(uri: "ssap://system.launcher/launch",
                   payload: ["id": appId])
    }

    // Legacy compatibility for PairTVView
    func fetchMacAddress(_ completion: @escaping (String?) -> Void) {
          guard registered else { completion(nil); return }
          let requestId = nextRequestId("sysinfo")
          let request: [String: Any] = [
              "id": requestId,
              "type": "request",
              "uri": "luna://com.webos.service.tv.systemproperty/getSystemInfo",
              "payload": ["keys": ["wifiMacAddress", "wiredMacAddress"]]
          ]
          pendingResponses[requestId] = { result in
              switch result {
              case .success(let payload):
                  let candidate = Self.extractMac(from: payload)
                  completion(candidate?.uppercased())
              case .failure:
                  completion(nil)
              }
          }
          send(request) { error in
              if let error {
                  self.resolvePending(for: requestId, with: .failure(error))
              }
          }
    }

      private static func extractMac(from payload: [String: Any]) -> String? {
          if let wifi = payload["wifiMacAddress"] as? String, !wifi.isEmpty { return wifi }
          if let wired = payload["wiredMacAddress"] as? String, !wired.isEmpty { return wired }
          if let net = payload["networkInfo"] as? [String: Any],
             let wifi = net["wifiMacAddress"] as? String, !wifi.isEmpty { return wifi }
          if let sysInfo = payload["systemInfo"] as? [String: Any] {
              return extractMac(from: sysInfo)
          }
          if let device = payload["device"] as? [String: Any] {
              return extractMac(from: device)
          }
          return nil
      }
}

// MARK: - Input remote helpers

private extension WebOSTV {

    func primeInputRemoteIfNeeded(completion: ((Bool) -> Void)? = nil) {
        guard registered else {
            completion?(false)
            return
        }

        if inputRemotePrimed {
            completion?(true)
            return
        }

        if let completion {
            inputRemoteWaiters.append(completion)
        }

        if inputRemotePriming {
            return
        }

        inputRemotePriming = true
        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/register",
                   payload: ["name": inputRemoteName]) { [weak self] error in
            guard let self else { return }
            let success = (error == nil)
            self.inputRemotePriming = false
            self.inputRemotePrimed = success

            let waiters = self.inputRemoteWaiters
            self.inputRemoteWaiters.removeAll()
            if !waiters.isEmpty {
                waiters.forEach { $0(success) }
            }

            if let error {
                DispatchQueue.main.async {
                    self.lastMessage = "Remote setup failed: \(error.localizedDescription)"
                }
            } else if !waiters.isEmpty {
                DispatchQueue.main.async {
                    self.lastMessage = "Remote ready."
                }
            }
        }
    }

    func resetInputRemoteState(andNotify notify: Bool) {
        let waiters = inputRemoteWaiters
        inputRemotePrimed = false
        inputRemotePriming = false
        inputRemoteWaiters.removeAll()

        if notify, !waiters.isEmpty {
            waiters.forEach { $0(false) }
        }
    }

    func sendButtonCommand(_ name: String) {
        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/sendButton",
                   payload: ["name": name]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.inputRemotePrimed = false
                DispatchQueue.main.async {
                    self.lastMessage = "Command \(name) failed: \(error.localizedDescription)"
                }
                self.primeInputRemoteIfNeeded()
            }
        }
    }
}


