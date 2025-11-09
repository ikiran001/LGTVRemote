// WebOSTV.swift
import Foundation
import Combine

/// High-level session over WebOSSocket.
/// - Connects via parallel ws/wss (handled by WebOSSocket)
/// - Only marks connected after the real socket open
/// - Guards every send so UI can’t spam when disconnected
final class WebOSTV: ObservableObject {

    // MARK: Published
    @Published private(set) var isConnected = false
    @Published private(set) var ip: String = ""
    @Published private(set) var lastMessage: String = ""

    // Optional callbacks (for haptics/animations)
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    // MARK: Internals
    private var socket: WebOSSocket?
    private var nextId = 1

    // Saved convenience
    static var savedIP: String?  { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP") }
    static var savedMAC: String? { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") }

    // MARK: Connect

    func connect(ip: String, completion: @escaping (Bool, String) -> Void) {
        self.ip = ip
        socket = WebOSSocket(allowInsecureLocalTLS: true)

        socket?.connect(host: ip,
                        onMessage: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s):
                    DispatchQueue.main.async { self.lastMessage = s }
                case .data(let d):
                    DispatchQueue.main.async { self.lastMessage = "binary(\(d.count))" }
                @unknown default:
                    break
                }
            case .failure(let err):
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.onDisconnect?()
                    self.lastMessage = "Socket error: \(err.localizedDescription)"
                }
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.isConnected = true
                    UserDefaults.standard.setValue(ip, forKey: "LGRemoteMVP.lastIP")
                    self.onConnect?()
                    completion(true, "Connected")
                case .failure(let err):
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
        DispatchQueue.main.async { self.isConnected = false; self.onDisconnect?() }
    }

    // MARK: Send helpers

    private func nextRequestId(_ prefix: String) -> String {
        defer { nextId += 1 }
        return "\(prefix)-\(nextId)"
    }

    private func send(_ object: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard isConnected, let sock = socket else {
            completion?(NSError(domain: "WebOSTV", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
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

    /// Generic request helper used by UI
    func sendSimple(uri: String, payload: [String: Any] = [:], completion: ((Error?) -> Void)? = nil) {
        guard isConnected else {
            completion?(NSError(domain: "WebOSTV", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "TV not connected"]))
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

    /// Send a remote key
    func sendButton(key: String) {
        guard isConnected else { return }
        sendSimple(uri: "ssap://com.webos.service.tv.inputremote/sendButton",
                   payload: ["name": key])
    }

    /// Launch an app by id (e.g. "youtube.leanback.v4", "netflix")
    func launchStreamingApp(_ appId: String) {
        guard isConnected else { return }
        sendSimple(uri: "ssap://system.launcher/launch",
                   payload: ["id": appId])
    }

    // MARK: PairTVView compatibility — best-effort MAC lookup

    /// Kept for compatibility with PairTVView. Many models won’t return this without luna perms,
    /// so we send a system property request and return nil if we can’t parse.
    func fetchMacAddress(_ completion: @escaping (String?) -> Void) {
        guard isConnected else { completion(nil); return }

        // Try to ask for system properties (may be ignored on some models)
        let req: [String: Any] = [
            "id": nextRequestId("sysinfo"),
            "type": "request",
            "uri": "luna://com.webos.service.tv.systemproperty/getSystemInfo",
            "payload": ["keys": ["wifiMacAddress", "wiredMacAddress"]]
        ]
        send(req) { _ in
            // NOTE: We are not parsing async responses here. Give the socket a moment,
            // then return nil so UI can fall back to manual entry if needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(nil)
            }
        }
    }
}

