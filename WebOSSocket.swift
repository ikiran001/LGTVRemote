import Foundation

/// WebOSSocket
/// - Starts BOTH sockets in parallel:
///     wss://<ip>:3001   (secure; accepts self-signed for LAN)
///     ws://<ip>:3000    (plain)
/// - The first one to call `didOpenWithProtocol` wins; the loser is cancelled.
/// - If one fails with -1005/-1001/-1202 etc., we keep waiting for the other.
/// - We only fail when BOTH candidates have failed/closed or an overall timer fires.
final class WebOSSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {

    // MARK: Public API

    init(allowInsecureLocalTLS: Bool = true) {
        self.allowInsecureLocalTLS = allowInsecureLocalTLS
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 8
        cfg.timeoutIntervalForResource = 8
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    func connect(
        host: String,
        onMessage: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        close() // cleanup old state

        self.targetHost     = host
        self.messageHandler = onMessage
        self.connectHandler = completion

        guard let wssURL = URL(string: "wss://\(host):3001/"),
              let wsURL  = URL(string: "ws://\(host):3000/") else {
            completion(.failure(NSError(domain: "WebOSSocket", code: -100, userInfo: [NSLocalizedDescriptionKey:"Bad host"]))); return
        }

        // Start both candidates
        primaryTask   = session.webSocketTask(with: wssURL) // secure first (many models require this)
        secondaryTask = session.webSocketTask(with: wsURL)

        // Overall connection deadline (covers “both hanging” case)
        overallTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.isOpen { self.failConnection(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey:"Connection timed out."])) }
        }

        primaryTask?.resume()
        secondaryTask?.resume()

        startReceiveLoop(primaryTask)
        startReceiveLoop(secondaryTask)
    }

    func send(_ text: String, completion: ((Error?) -> Void)? = nil) {
        guard let t = liveTask else {
            completion?(NSError(domain: "WebOSSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
            return
        }
        t.send(.string(text)) { completion?($0) }
    }

    func close() {
        overallTimer?.invalidate(); overallTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        liveTask?.cancel(with: .goingAway, reason: nil); liveTask = nil
        primaryTask?.cancel(with: .goingAway, reason: nil); primaryTask = nil
        secondaryTask?.cancel(with: .goingAway, reason: nil); secondaryTask = nil
        primaryFailed = false
        secondaryFailed = false
        isOpen = false
    }

    // MARK: Internals

    private var session: URLSession!
    private var primaryTask: URLSessionWebSocketTask?     // wss:3001
    private var secondaryTask: URLSessionWebSocketTask?   // ws:3000
    private var liveTask: URLSessionWebSocketTask?

    private var isOpen = false
    private var primaryFailed = false
    private var secondaryFailed = false

    private var targetHost = ""
    private let allowInsecureLocalTLS: Bool

    private var messageHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var connectHandler: ((Result<Void, Error>) -> Void)?

    private var overallTimer: Timer?
    private var pingTimer: Timer?

    private func startReceiveLoop(_ task: URLSessionWebSocketTask?) {
        task?.receive { [weak self] result in
            guard let self else { return }
            if let t = task, t === self.liveTask {
                self.messageHandler?(result)
                self.startReceiveLoop(task)
            } else {
                // Still racing or loser; keep listening so we can promote if needed.
                self.startReceiveLoop(task)
            }
        }
    }

    private func promote(_ task: URLSessionWebSocketTask) {
        guard !isOpen else { return }
        isOpen   = true
        liveTask = task

        // Cancel the other candidate
        if task === primaryTask { secondaryTask?.cancel(with: .goingAway, reason: nil) }
        if task === secondaryTask { primaryTask?.cancel(with: .goingAway, reason: nil) }
        primaryTask = nil
        secondaryTask = nil

        overallTimer?.invalidate(); overallTimer = nil
        startPinging()

        connectHandler?(.success(()))
        connectHandler = nil
    }

    private func failConnection(_ error: Error) {
        close()
        connectHandler?(.failure(error))
        connectHandler = nil
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            guard let t = self?.liveTask else { return }
            t.sendPing { _ in }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        promote(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === liveTask {
            failConnection(NSError(domain: "WebOSSocket", code: Int(closeCode.rawValue), userInfo: [NSLocalizedDescriptionKey: "Socket closed (\(closeCode.rawValue))"]))
            return
        }
        // mark candidate as failed; if both are gone and not open => fail
        if webSocketTask === primaryTask { primaryFailed = true }
        if webSocketTask === secondaryTask { secondaryFailed = true }
        if !isOpen && primaryFailed && secondaryFailed {
            failConnection(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSLocalizedDescriptionKey:"Both ws and wss failed."]))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // If liveTask died, surface error; if candidate died and other hasn't opened yet, keep waiting.
        if task === liveTask {
            failConnection(error)
        } else {
            if task === primaryTask { primaryFailed = true }
            if task === secondaryTask { secondaryFailed = true }
            if !isOpen && primaryFailed && secondaryFailed {
                failConnection(error)
            }
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
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}

