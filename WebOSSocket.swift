//
// WebOSSocket.swift
// Robust, logging-enabled WebSocket wrapper for LG webOS sockets
//
// Replace the existing WebOSSocket.swift with this file.
// Expects to be used by WebOSTV.swift (send strings, receive messages).
//

import Foundation

final class WebOSSocket: NSObject, URLSessionWebSocketDelegate {

    // Public
    private(set) var allowInsecureLocalTLS: Bool = true

    // Internals
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var onMessageHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var onConnectHandler: ((Result<Void, Error>) -> Void)?
    private var isClosedExplicitly = false

    init(allowInsecureLocalTLS: Bool = true) {
        super.init()
        self.allowInsecureLocalTLS = allowInsecureLocalTLS
    }

    // MARK: - Connect (tries multiple candidate URLs)

    /// Connect to the TV. This will attempt a small set of ws/wss + port combinations
    /// and pick the first that responds. onMessage receives raw URLSessionWebSocketTask.Message results.
    func connect(
        host: String,
        onMessage: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("🔌 [WebOSSocket] FORCED connect to ws://\(host):3000")
        self.onMessageHandler = onMessage
        self.onConnectHandler = completion
        self.isClosedExplicitly = false

        guard let url = URL(string: "ws://\(host):3000") else {
            completion(.failure(NSError(domain:"WebOSSocket", code:-1, userInfo:[NSLocalizedDescriptionKey:"Invalid URL"])))
            return
        }

        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.task = session.webSocketTask(with: url)
        self.task?.resume()

        // Start listening loop (existing method in file)
        self.listen()

        // Wait a short moment for any immediate server message, then call completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion(.success(()))
        }
    }



    // MARK: Try candidate helper

    private func tryNextCandidate(candidates: [URL], index: Int, host: String) {
        if index >= candidates.count {
            let err = NSError(domain: "WebOSSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidate URL succeeded"])
            print("❌ [WebOSSocket] All candidate URLs failed for host \(host)")
            DispatchQueue.main.async { self.onConnectHandler?(.failure(err)) }
            return
        }

        let url = candidates[index]
        print("🔄 [WebOSSocket] Trying candidate: \(url.absoluteString)")

        // configure session every attempt so that delegate callback for TLS trust works
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session

        self.task = session.webSocketTask(with: url)
        self.task?.resume()

        // We try to receive once to judge basic liveliness (some TVs reply immediately).
        var attemptSucceeded = false

        // If the server sends any message quickly we'll accept this candidate.
        self.task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                attemptSucceeded = true
                print("⬅️ [WebOSSocket] candidate success. First message: \(msg)")
                // deliver first message to handler
                self.onMessageHandler?(Result.success(msg))
                // Switch to continuous listen loop
                self.listen()
                DispatchQueue.main.async { self.onConnectHandler?(.success(())) }
            case .failure(let err):
                // Candidate failed - close and try next
                print("❌ [WebOSSocket] candidate \(url.absoluteString) failed with error: \(err.localizedDescription)")
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                // small delay then try next candidate
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.tryNextCandidate(candidates: candidates, index: index + 1, host: host)
                }
            }
        }

        // Timeout guard: if no message within this short window, try next
        let timeout = DispatchTime.now() + .milliseconds(2500)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: timeout) { [weak self] in
            guard let self = self else { return }
            if !attemptSucceeded {
                print("⏱ [WebOSSocket] candidate \(url.absoluteString) timed out, trying next")
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.tryNextCandidate(candidates: candidates, index: index + 1, host: host)
                }
            }
        }
    }

    // MARK: - Send helpers

    /// Send a text payload (JSON string). Logs outgoing payload.
    func send(_ text: String, completion: ((Error?) -> Void)? = nil) {
        guard let task = task else {
            let err = NSError(domain: "WebOSSocket", code: -999, userInfo: [NSLocalizedDescriptionKey: "No active socket"])
            print("❌ [WebOSSocket] send() called but socket is nil")
            completion?(err)
            return
        }
        print("➡️ [WebOSSocket → OUT] \(text)")
        task.send(.string(text)) { error in
            if let e = error { print("❌ [WebOSSocket] Send error: \(e.localizedDescription)") }
            completion?(error)
        }
    }

    // Continuous receive loop
    private func listen() {
        guard let task = task else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                // Log message contents
                switch msg {
                case .string(let s): print("⬅️ [WebOSSocket ← IN (text)] \(s)")
                case .data(let d): print("⬅️ [WebOSSocket ← IN (data)] length=\(d.count)")
                @unknown default: print("⬅️ [WebOSSocket ← IN] unknown message type")
                }
                self.onMessageHandler?(Result.success(msg))
                // continue listening
                self.listen()
            case .failure(let err):
                print("❌ [WebOSSocket] Receive error: \(err.localizedDescription)")
                // close task and notify handler
                self.onMessageHandler?(Result.failure(err))
                // if not closed explicitly, call onConnectHandler failure so callers know
                if !self.isClosedExplicitly {
                    DispatchQueue.main.async {
                        self.onConnectHandler?(.failure(err))
                    }
                }
                // cleanup
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
            }
        }
    }

    // Close gently
    func close() {
        print("🛑 [WebOSSocket] Closing socket (explicit)")
        isClosedExplicitly = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    // MARK: - URLSessionWebSocketDelegate (TLS trust for local IPs)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        guard allowInsecureLocalTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              isLocalRFC1918(host: challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Accept the local self-signed / internal cert for RFC1918 hosts
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

