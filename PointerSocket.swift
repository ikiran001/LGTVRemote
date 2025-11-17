// PointerSocket.swift
// Minimal pointer socket wrapper used by WebOSTV
// Paste this as a new file in your project.

import Foundation

/// A small wrapper that connects to a pointer input socket (websocket),
/// exposes `isReady`, `sendButton(_:)`, and `onDisconnect` to the caller.
/// It tries to send pointer-style button messages expected by LG TVs.
final class PointerSocket: NSObject, URLSessionWebSocketDelegate {
    private let host: String
    private let clientKey: String?
    private let allowInsecureLocalTLS: Bool

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private(set) var isReady = false

    /// Called when the socket disconnects. Error may be nil for normal close.
    var onDisconnect: ((Error?) -> Void)?

    init(host: String, clientKey: String?, allowInsecureLocalTLS: Bool = true) {
        self.host = host
        self.clientKey = clientKey
        self.allowInsecureLocalTLS = allowInsecureLocalTLS
        super.init()
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// Connect to the first successful URL in `urls`.
    /// Completion uses explicit types so the compiler is happy.
    func connect(urls: [URL], completion: @escaping (Bool, Error?) -> Void) {
        close() // reset

        guard !urls.isEmpty else {
            completion(false, NSError(domain: "PointerSocket", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "No URLs provided"]))
            return
        }

        // Attempt candidates sequentially
        tryConnect(urls: urls, index: 0, completion: completion)
    }

    private func tryConnect(urls: [URL], index: Int, completion: @escaping (Bool, Error?) -> Void) {
        guard index < urls.count else {
            completion(false, NSError(domain: "PointerSocket", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "No reachable pointer URL"]))
            return
        }

        let url = urls[index]
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Give it a brief time to open and exchange messages — use receive to detect state
        // We'll wait for either the receive to return or a short delay.
        // If open, mark isReady and report success.
        // If fail quickly, close and try next.

        // Set a timeout guard
        let timeout = DispatchTime.now() + .seconds(6)
        var succeeded = false

        // Start a receive loop to detect readiness (some TVs send initial messages)
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                // Any message from server indicates liveliness. Mark ready.
                self.isReady = true
                succeeded = true
                // We accept the message silently; don't crash on binary/text differences.
                // Keep the receive loop alive on main thread
                self.startReceiveLoop()
                DispatchQueue.main.async { completion(true, nil) }
            case .failure(let err):
                // Fail this candidate and try next
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isReady = false
                // try next candidate
                self.tryConnect(urls: urls, index: index + 1, completion: completion)
            @unknown default:
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isReady = false
                self.tryConnect(urls: urls, index: index + 1, completion: completion)
            }
        }

        // If we hit timeout and haven't succeeded, try next candidate
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: timeout) { [weak self] in
            guard let self = self else { return }
            if !succeeded {
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isReady = false
                DispatchQueue.main.async {
                    self.tryConnect(urls: urls, index: index + 1, completion: completion)
                }
            }
        }
    }

    private func startReceiveLoop() {
        guard let task = self.task else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // keep listening — we don't need to parse incoming pointer server messages here
                self.startReceiveLoop()
            case .failure(let err):
                // Socket closed or errored
                self.isReady = false
                self.task = nil
                self.onDisconnect?(err)
            @unknown default:
                self.isReady = false
                self.task = nil
                self.onDisconnect?(nil)
            }
        }
    }

    /// Send a pointer-style button. Implementation uses a simple JSON message format.
    func sendButton(_ key: String) {
        guard let task = task, isReady else { return }
        // pointer socket message expected shape differs across TVs; this is a generic attempt.
        // The TV usually expects something like { "type":"button", "button":"ENTER" } or similar.
        // We'll send a few variants to improve compatibility.
        let messages: [String] = [
            "{\"type\":\"button\",\"name\":\"\(key)\"}",
            "{\"type\":\"button\",\"button\":\"\(key)\"}",
            "{\"type\":\"pointer_event\",\"button\":\"\(key)\"}"
        ]

        for msg in messages {
            task.send(.string(msg)) { _ in /* ignore send error here; higher level will detect disconnect */ }
        }
    }

    func close() {
        isReady = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: URLSessionWebSocketDelegate - handle TLS trust for local IPs (if needed)
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Trust local RFC1918 hosts if allowInsecureLocalTLS is set
        guard allowInsecureLocalTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              isLocalRFC1918(host: challenge.protectionSpace.host) else {
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
//
//  PointerSocket.swift
//  LGRemoteMVP
//
//  Created by Kiran Jadhav on 17/11/25.
//

