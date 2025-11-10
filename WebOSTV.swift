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
        if type == "registered" {
            if let payload = dict["payload"] as? [String: Any],
               let key = payload["client-key"] as? String {
                Self.savedClientKey = key
            }
            DispatchQueue.main.async {
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                self.onConnect?()
                self.completeConnect(true, "Registered ✓")
            }
            return
        }

        if type == "error" {
            let msg = (dict["error"] as? String) ?? "Unknown register error"
            failEarly("TV error: \(msg)")
        }

        if let payload = dict["payload"] as? [String: Any],
           let pairingType = payload["pairingType"] as? String,
           pairingType == "PROMPT",
           let key = payload["client-key"] as? String {
            Self.savedClientKey = key
            DispatchQueue.main.async {
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                self.onConnect?()
                self.completeConnect(true, "Registered ✓")
            }
            return
        }

    }

    private func failEarly(_ reason: String) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.registered = false
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

    func sendButton(key: String) {
        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/sendButton",
                   payload: ["name": key])
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

