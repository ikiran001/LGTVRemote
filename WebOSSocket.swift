//
//  WebOSSocket.swift
//  LGRemoteMVP
//
//  Rebuilt connector that negotiates the official LG sub-protocol
//  and falls back through ws/wss + 3000/3001 automatically.
//

import Foundation

final class WebOSSocket: NSObject, URLSessionWebSocketDelegate {

    // Public
    private(set) var allowInsecureLocalTLS: Bool = true

    // Internals
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var onMessageHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var onConnectHandler: ((Result<Void, Error>) -> Void)?
    private var isClosedExplicitly = false

    private struct SocketCandidate {
        let url: URL
        let subprotocols: [String]
    }

    private var candidateRequests: [SocketCandidate] = []
    private var currentCandidateIndex = 0
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var connectSuccessDelivered = false
    private var isListening = false
    private var lastConnectionError: Error?

    private let subprotocolAttempts: [[String]] = [
        ["lgtv-protocol"],
        ["lgtv"],
        []
    ]

    init(allowInsecureLocalTLS: Bool = true) {
        self.allowInsecureLocalTLS = allowInsecureLocalTLS
        super.init()
    }

    deinit {
        teardownTask()
    }

    // MARK: - Connect (tries multiple candidate URLs)

    /// Connect to the TV. This will attempt common ws/wss + port combinations until one succeeds.
    func connect(
        host: String,
        onMessage: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            completion(.failure(Self.makeError("Host is empty")))
            return
        }

        onMessageHandler = onMessage
        onConnectHandler = completion
        isClosedExplicitly = false
        connectSuccessDelivered = false
        lastConnectionError = nil

        teardownTask()

        candidateRequests = buildCandidateRequests(for: trimmedHost)
        currentCandidateIndex = 0

        guard !candidateRequests.isEmpty else {
            completion(.failure(Self.makeError("Invalid host \(trimmedHost)")))
            return
        }

        startCandidateAttempt()
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

    // MARK: - Close

    func close() {
        print("🛑 [WebOSSocket] Closing socket (explicit)")
        isClosedExplicitly = true
        connectSuccessDelivered = false
        candidateRequests.removeAll()
        currentCandidateIndex = 0
        lastConnectionError = nil
        teardownTask()
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

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: - Candidate handling

    private func buildCandidateRequests(for rawHost: String) -> [SocketCandidate] {
        let (hostOnly, explicitPort) = splitHostAndPort(rawHost)
        guard !hostOnly.isEmpty else { return [] }

        var ports: [Int] = []
        if let explicitPort = explicitPort { ports.append(explicitPort) }
        for defaultPort in [3000, 3001] where !ports.contains(defaultPort) {
            ports.append(defaultPort)
        }

        var urls: [URL] = []
        var seen = Set<String>()
        for port in ports {
            let schemes = preferredSchemes(for: port, explicitPort: explicitPort)
            for scheme in schemes {
                let urlString = "\(scheme)://\(hostOnly):\(port)/"
                guard let url = URL(string: urlString) else { continue }
                if seen.insert(url.absoluteString).inserted {
                    urls.append(url)
                }
            }
        }

        var requests: [SocketCandidate] = []
        for url in urls {
            for subprotocols in subprotocolAttempts {
                requests.append(SocketCandidate(url: url, subprotocols: subprotocols))
            }
        }
        return requests
    }

    private func preferredSchemes(for port: Int, explicitPort: Int?) -> [String] {
        if let explicitPort = explicitPort, explicitPort == port {
            return port == 3001 ? ["wss", "ws"] : ["ws", "wss"]
        }
        return port == 3001 ? ["wss", "ws"] : ["ws", "wss"]
    }

    private func splitHostAndPort(_ raw: String) -> (String, Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        if trimmed.contains("://"), let comps = URLComponents(string: trimmed) {
            let host = comps.host ?? ""
            return (host.isEmpty ? trimmed : host, comps.port)
        }

        if trimmed.first == "[", let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.startIndex...closing])
            let remainder = trimmed[trimmed.index(after: closing)...]
            if remainder.first == ":", let port = Int(remainder.dropFirst()) {
                return (host, port)
            }
            return (host, nil)
        }

        if let colon = trimmed.lastIndex(of: ":"), colon != trimmed.startIndex {
            let portSubstring = trimmed[trimmed.index(after: colon)...]
            if portSubstring.allSatisfy({ $0.isNumber }), let port = Int(portSubstring) {
                let hostPart = trimmed[..<colon]
                return (String(hostPart), port)
            }
        }

        return (trimmed, nil)
    }

    private func startCandidateAttempt() {
        guard !isClosedExplicitly else { return }
        guard currentCandidateIndex < candidateRequests.count else {
            notifyConnectFailureUsingLastError()
            return
        }

        let candidate = candidateRequests[currentCandidateIndex]
        let url = candidate.url
        let protocolLabel = candidate.subprotocols.isEmpty ? "none" : candidate.subprotocols.joined(separator: ",")

        print("🔄 [WebOSSocket] Trying candidate: \(url.absoluteString) [protocols: \(protocolLabel)]")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        guard let session = session else { return }

        let wsTask = session.webSocketTask(with: url, protocols: candidate.subprotocols)
        task = wsTask
        isListening = false
        wsTask.resume()

        scheduleHandshakeTimeout(for: wsTask, url: url)

        wsTask.sendPing(pongReceiveHandler: { [weak self, weak wsTask] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let wsTask = wsTask, self.task === wsTask else { return }
                self.handshakeTimeoutWorkItem?.cancel()
                self.handshakeTimeoutWorkItem = nil
                if let error = error {
                    print("❌ [WebOSSocket] \(url.absoluteString) ping failed: \(error.localizedDescription)")
                    self.advanceCandidate(after: error)
                } else {
                    self.handleHandshakeSuccess(url: url)
                }
            }
        })
    }

    private func scheduleHandshakeTimeout(for task: URLSessionWebSocketTask, url: URL) {
        handshakeTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak task] in
            guard let self = self else { return }
            guard let task = task, self.task === task else { return }
            guard !self.connectSuccessDelivered, !self.isClosedExplicitly else { return }
            print("⏱ [WebOSSocket] \(url.absoluteString) handshake timed out")
            let timeoutError = Self.makeError("Handshake timed out", code: -2)
            self.advanceCandidate(after: timeoutError)
        }
        handshakeTimeoutWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    private func handleHandshakeSuccess(url: URL) {
        print("✅ [WebOSSocket] Connected via \(url.absoluteString)")
        if !isListening {
            listen()
        }
        if !connectSuccessDelivered {
            connectSuccessDelivered = true
            DispatchQueue.main.async {
                self.onConnectHandler?(.success(()))
            }
        }
    }

    private func advanceCandidate(after error: Error) {
        lastConnectionError = error
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        teardownTask()

        guard !isClosedExplicitly else { return }

        currentCandidateIndex += 1
        if currentCandidateIndex < candidateRequests.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.startCandidateAttempt()
            }
        } else if !connectSuccessDelivered {
            DispatchQueue.main.async {
                self.onConnectHandler?(.failure(error))
            }
        }
    }

    private func notifyConnectFailureUsingLastError() {
        guard !connectSuccessDelivered else { return }
        let error = lastConnectionError ?? Self.makeError("No candidate URL succeeded")
        DispatchQueue.main.async {
            self.onConnectHandler?(.failure(error))
        }
    }

    // MARK: - Receive loop

    private func listen() {
        guard let task = task else {
            isListening = false
            return
        }
        isListening = true
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s): print("⬅️ [WebOSSocket ← IN (text)] \(s)")
                case .data(let d): print("⬅️ [WebOSSocket ← IN (data)] length=\(d.count)")
                @unknown default: print("⬅️ [WebOSSocket ← IN] unknown message type")
                }
                self.onMessageHandler?(Result.success(msg))
                self.listen()
            case .failure(let err):
                self.isListening = false
                print("❌ [WebOSSocket] Receive error: \(err.localizedDescription)")
                if !self.isClosedExplicitly {
                    self.onMessageHandler?(Result.failure(err))
                }
                if !self.isClosedExplicitly && !self.connectSuccessDelivered {
                    DispatchQueue.main.async {
                        self.onConnectHandler?(.failure(err))
                    }
                }
                self.teardownTask()
            }
        }
    }

    private func teardownTask() {
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        isListening = false
        if let task = task {
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Helpers

    private static func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(domain: "WebOSSocket", code: code, userInfo: [NSLocalizedDescriptionKey: message])
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

