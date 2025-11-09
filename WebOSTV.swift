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
        registered = false
        isConnected = false

        socket = WebOSSocket(allowInsecureLocalTLS: true)

        socket?.connect(host: ip,
                        onMessage: { [weak self] result in
            self?.handleSocketMessage(result)
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Socket is open; now we must REGISTER before we can send commands.
                self.performRegisterHandshake()
            case .failure(let err):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.onDisconnect?()
                    completion(false, err.localizedDescription)
                }
            }
        })
    }

    func disconnect() {
        socket?.close()
        socket = nil
        registered = false
        DispatchQueue.main.async {
            self.isConnected = false
            self.onDisconnect?()
        }
    }

    // MARK: Pairing / Register

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

        let req: [String: Any] = [
            "id": "register-\(UUID().uuidString.prefix(6))",
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
        if type == "registered" || (dict["payload"] as? [String: Any])?["pairingType"] as? String == "PROMPT" {
            // Successful registration
            if let payload = dict["payload"] as? [String: Any],
               let key = payload["client-key"] as? String {
                Self.savedClientKey = key
            }
            DispatchQueue.main.async {
                self.registered = true
                self.isConnected = true
                self.onConnect?()
            }
        } else if type == "error" {
            let msg = (dict["error"] as? String) ?? "Unknown register error"
            failEarly("TV error: \(msg)")
        }
    }

    private func failEarly(_ reason: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.registered = false
            self.onDisconnect?()
            self.lastMessage = reason
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

    /// Generic request for ssap:// URIs
    func sendSimple(uri: String, payload: [String: Any] = [:], completion: ((Error?) -> Void)? = nil) {
        guard registered else {
            completion?(NSError(domain: "WebOSTV", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "TV not registered yet"]))
            return
        }
        let req: [String: Any] = [
            "id": nextRequestId("req"),
            "type": "request",
            "uri": uri,
            "payload": payload
        ]
        send(req, completion: completion)
    }

    /// Remote key
    func sendButton(key: String) {
        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/sendButton",
                   payload: ["name": key])
    }

    /// Launch app by ID
    func launchStreamingApp(_ appId: String) {
        sendSimple(uri: "ssap://system.launcher/launch",
                   payload: ["id": appId])
    }

    // Legacy compatibility for PairTVView
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
}

