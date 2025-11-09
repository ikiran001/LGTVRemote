import Foundation

/// WebOSSocket
/// - Prefers the secure `wss://` transport (port 3001) and falls back to `ws://` (port 3000) only if needed.
/// - Attempts each candidate sequentially instead of racing, which reduces connection-reset churn when TVs
///   immediately drop the insecure socket.
final class WebOSSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {

    private typealias SocketCandidate = (url: URL, protocols: [String])

    // MARK: Public API

    init(allowInsecureLocalTLS: Bool = true) {
        self.allowInsecureLocalTLS = allowInsecureLocalTLS
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func connect(
        host: String,
        onMessage: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        close() // reset previous state

        messageHandler = onMessage
        connectHandler = completion
        targetHost = host

        candidateQueue.removeAll()
        if let secureURL = URL(string: "wss://\(host):3001/") {
            enqueueCandidates(for: secureURL)
        }
        if let insecureURL = URL(string: "ws://\(host):3000/") {
            enqueueCandidates(for: insecureURL)
        }

        guard !candidateQueue.isEmpty else {
            completion(.failure(NSError(domain: "WebOSSocket",
                                        code: -100,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid host: \(host)"])))
            return
        }

        attemptNextCandidate()
    }

    func send(_ text: String, completion: ((Error?) -> Void)? = nil) {
        guard let task = currentTask, isOpen else {
            completion?(NSError(domain: "WebOSSocket",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
            return
        }

        task.send(.string(text)) { completion?($0) }
    }

    func close() {
        overallTimer?.invalidate(); overallTimer = nil
        pingTimer?.invalidate(); pingTimer = nil

        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil

        candidateQueue.removeAll()
        lastError = nil
        isOpen = false
    }

    // MARK: Internals

    private var session: URLSession!
    private var messageHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var connectHandler: ((Result<Void, Error>) -> Void)?

    private let preferredSubprotocols = ["lgtv"]

    private var candidateQueue: [SocketCandidate] = []
    private var currentTask: URLSessionWebSocketTask?
    private var overallTimer: Timer?
    private var pingTimer: Timer?

    private var isOpen = false
    private var lastError: Error?
    private var targetHost: String = ""
    private let allowInsecureLocalTLS: Bool

    private func attemptNextCandidate() {
        overallTimer?.invalidate(); overallTimer = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
        isOpen = false

        guard !candidateQueue.isEmpty else {
            failConnection(lastError ?? NSError(domain: NSURLErrorDomain,
                                                code: NSURLErrorCannotConnectToHost,
                                                userInfo: [NSLocalizedDescriptionKey: "Unable to reach \(targetHost)."]))
            return
        }

        let nextCandidate = candidateQueue.removeFirst()
        let task: URLSessionWebSocketTask
        if nextCandidate.protocols.isEmpty {
            task = session.webSocketTask(with: nextCandidate.url)
        } else {
            task = session.webSocketTask(with: nextCandidate.url, protocols: nextCandidate.protocols)
        }
        currentTask = task

        scheduleOverallTimer()
        startReceiveLoop(for: task)
        task.resume()
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard task === self.currentTask else { return } // stale callback

            switch result {
            case .success:
                self.messageHandler?(result)
                self.startReceiveLoop(for: task)
            case .failure(let error):
                if self.isOpen {
                    self.messageHandler?(.failure(error))
                    self.failConnection(error)
                } else {
                    self.lastError = error
                    self.attemptNextCandidate()
                }
            }
        }
    }

    private func scheduleOverallTimer() {
        overallTimer?.invalidate()
        overallTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            guard let self, !self.isOpen else { return }
            self.lastError = NSError(domain: NSURLErrorDomain,
                                     code: NSURLErrorTimedOut,
                                     userInfo: [NSLocalizedDescriptionKey: "Connection timed out."])
            self.attemptNextCandidate()
        }
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let task = self?.currentTask, self?.isOpen == true else { return }
            task.sendPing { _ in }
        }
    }

    private func failConnection(_ error: Error) {
        close()
        connectHandler?(.failure(error))
        connectHandler = nil
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard webSocketTask === currentTask else { return }

        isOpen = true
        lastError = nil
        overallTimer?.invalidate(); overallTimer = nil

        startPinging()
        connectHandler?(.success(()))
        connectHandler = nil
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard webSocketTask === currentTask else { return }

        let error = NSError(domain: "WebOSSocket",
                            code: Int(closeCode.rawValue),
                            userInfo: [NSLocalizedDescriptionKey: "Socket closed (\(closeCode.rawValue))"])

        if isOpen {
            messageHandler?(.failure(error))
            failConnection(error)
        } else {
            lastError = error
            attemptNextCandidate()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, task === currentTask else { return }

        if isOpen {
            messageHandler?(.failure(error))
            failConnection(error)
        } else {
            lastError = error
            attemptNextCandidate()
        }
    }

    // MARK: URLSessionDelegate (TLS trust for LAN)

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
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

    private func enqueueCandidates(for url: URL) {
        if !preferredSubprotocols.isEmpty {
            candidateQueue.append((url, preferredSubprotocols))
        }
        candidateQueue.append((url, []))
    }
}
