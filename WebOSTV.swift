// WebOSTV.swift
// Updated: force pointer mode, ignore failing input services, more fallback IDs,
// retry on 500 errors, and proactively open pointer socket before button events.

import Foundation
import Combine

final class WebOSTV: ObservableObject {

    // MARK: Published state for UI
    @Published private(set) var isConnected = false
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

    // Input / pointer management
    private var inputRemotePrimed = false
    private var inputRemotePriming = false
    private var queuedButtons: [String] = []
    private var retryingButtonKey: String?
    private var failedButtonServices: Set<String> = []

    private struct InputRemoteService: Equatable {
        let registerURI: String
        let sendButtonURI: String
    }

    private struct PointerService {
        let requestURI: String
    }

    private let inputRemoteButtonCandidates: [InputRemoteService] = [
        InputRemoteService(registerURI: "ssap://com.webos.service.tv.inputremote/register",
                           sendButtonURI: "ssap://com.webos.service.tv.inputremote/sendButton"),
        InputRemoteService(registerURI: "ssap://com.webos.service.remoteinput/register",
                           sendButtonURI: "ssap://com.webos.service.remoteinput/sendButton"),
        InputRemoteService(registerURI: "ssap://com.webos.service.tvinputremote/register",
                           sendButtonURI: "ssap://com.webos.service.tvinputremote/sendButton")
    ]

    private let pointerServiceCandidates: [PointerService] = [
        PointerService(requestURI: "ssap://com.webos.service.tv.inputremote/getPointerInputSocket"),
        PointerService(requestURI: "ssap://com.webos.service.networkinput/getPointerInputSocket"),
        // extra candidate URIs if some TV firmwares use different names
        PointerService(requestURI: "ssap://com.webos.service.tvpointer/getPointerInputSocket")
    ]

    private var activeInputRemoteService: InputRemoteService?
    private var pointerSocket: PointerSocket?
    private var clientKey: String? = WebOSTV.savedClientKey

    // More robust app fallback mapping (extended)
    private struct StreamingAppFallback {
        let alternates: [String]
        let keywordGroups: [[String]]
    }

    private let streamingAppFallbacks: [String: StreamingAppFallback] = {
        let prime = StreamingAppFallback(
            alternates: [
                "amazon-webos", "amazon-webos-us", "primevideo", "com.amazon.amazonvideo.webos",
                "com.amazon.ignition", "amazonprimevideo", "com.webos.app.amazonprimevideo",
                "com.amazon.shoptv.webos", "primevideo-webos", "amazonprimevideo-webos",
                "amzn.tvarm", "com.amazon.shoptv"
            ],
            keywordGroups: [["prime","video"], ["amazon","prime"], ["prime"]]
        )
        let netflix = StreamingAppFallback(
            alternates: ["netflix", "com.netflix.app"], // include common variants
            keywordGroups: [["netflix"]]
        )
        let hotstar = StreamingAppFallback(
            alternates: ["disneyplus-hotstar", "hotstar", "com.disney.disneyplus-in", "com.star.hotstar", "disney.hotstar"],
            keywordGroups: [["hotstar"], ["disney","hotstar"], ["disney"]]
        )
        let sonyLiv = StreamingAppFallback(
            alternates: ["sonyliv-webos", "com.sonyliv", "com.sonyliv.sonyliv", "sonyliv", "in.sonyliv.webos"],
            keywordGroups: [["sony","liv"], ["sonyliv"], ["sony"]]
        )
        let jioCinema = StreamingAppFallback(
            alternates: [
                "com.jio.media.jioplay", "jiocinema", "com.jio.media.ondemand",
                "com.jio.jioplay.tv", "com.jio.jioplay", "com.jio.media.jioplay.tv",
                "jiocinema-webos", "com.reliance.jiocinema"
            ],
            keywordGroups: [["jio","cinema"], ["jiocinema"], ["jio"]]
        )

        var map: [String: StreamingAppFallback] = [:]

        // populate canonical -> fallback
        let groups: [(keys:[String], fallback: StreamingAppFallback)] = [
            (["amzn.tvarm","amazon-webos","primevideo","com.amazon.amazonvideo.webos"], prime),
            (["netflix","com.netflix.app"], netflix),
            (["com.startv.hotstar.lg", "disneyplus-hotstar","hotstar"], hotstar),
            (["com.sonyliv.lg","sonyliv-webos","com.sonyliv"], sonyLiv),
            (["com.jio.media.jioplay.tv","com.jio.media.jioplay","jiocinema"], jioCinema)
        ]

        for (keys, fallback) in groups {
            for k in keys { map[k] = fallback }
            // also insert alternates from fallback
            for alt in fallback.alternates { map[alt] = fallback }
        }

        return map
    }()

    private let streamingAppDisplayNames: [String: String] = [
        "amzn.tvarm": "Prime Video",
        "amazon-webos": "Prime Video",
        "primevideo": "Prime Video",
        "netflix": "Netflix",
        "com.startv.hotstar.lg": "Disney+ Hotstar",
        "com.sonyliv.lg": "Sony LIV",
        "com.jio.media.jioplay.tv": "JioCinema"
    ]

    private struct TVApp: Equatable {
        let id: String
        let title: String
    }

    private var installedApps: [TVApp] = []
    private var lastAppFetchDate: Date?
    private var appFetchCallbacks: [(Result<[TVApp], Error>) -> Void] = []

    // Persisted convenience
    static var savedIP: String?  { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP") }
    static var savedMAC: String? { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") }
    private static var savedClientKey: String? {
        get { UserDefaults.standard.string(forKey: "LGRemoteMVP.clientKey") }
        set { UserDefaults.standard.setValue(newValue, forKey: "LGRemoteMVP.clientKey") }
    }

    // MARK: Connect

    func connect(ip: String, completion: @escaping (Bool, String) -> Void) {
        self.ip = ip
        connectCompletion = completion
        registered = false
        isConnected = false
        inputRemotePrimed = false
        inputRemotePriming = false
        queuedButtons.removeAll()
        retryingButtonKey = nil
        failedButtonServices.removeAll()
        installedApps.removeAll()
        lastAppFetchDate = nil
        cancelAppFetches(reason: "Connecting to new TV")
        pointerSocket?.close()
        pointerSocket = nil
        activeInputRemoteService = nil
        clientKey = WebOSTV.savedClientKey
        cancelAllPendingRequests(message: "Previous requests cancelled")
        lastMessage = "Pinging \(ip)…"

        // 1) quick reachability (prefer the secure 3001 port, fall back to 3000)
        Ping.isReachable(ip: ip, port: 3001, timeout: 0.7) { [weak self] reachableSecure in
            guard let self else { return }
            if reachableSecure {
                self.openSocketAndRegister()
                return
            }
            Ping.isReachable(ip: ip, port: 3000, timeout: 0.7) { [weak self] reachableLegacy in
                guard let self else { return }
                if reachableLegacy {
        // quick reachability (uses Ping helper)
        Ping.isReachable(ip: ip, port: 3000, timeout: 0.7) { [weak self] reachable in
            guard let self else { return }
            if !reachable {
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
                    return
                }
                DispatchQueue.main.async {
                    self.lastMessage = "TV at \(ip) didn’t respond on 3001/3000. Check Wi-Fi / LG Connect Apps."
                }
                self.completeConnect(false, "Host not reachable")
            }
        }
    }

    // MARK: - Request helpers (with retry on server errors)

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

    /// sendSimple with retry on 5xx server errors (exponential backoff)
    func sendSimple(uri: String,
                    payload: [String: Any] = [:],
                    retries: Int = 2,
                    completion: ((Result<[String: Any], Error>) -> Void)? = nil) {

        guard registered else {
            completion?(.failure(makeTVError("TV not registered yet", code: -3)))
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

        // wrapper to send and optionally retry on server error
        func attemptSend(remaining: Int, delay: TimeInterval = 0.0) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.send(req) { error in
                    if let error,
                       self.shouldRetryForError(error) && remaining > 0 {
                        // remove and re-add handler (it stays in pendingResponses keyed)
                        let backoff = Double( (2 * (2 - remaining + 1)) ) * 0.15 // small backoff
                        attemptSend(remaining: remaining - 1, delay: backoff)
                        return
                    }
                    if let error {
                        if let handler = self.pendingResponses.removeValue(forKey: requestId) {
                            DispatchQueue.main.async { handler(.failure(error)) }
                        } else {
                            // no handler — ignore
                        }
                    }
                }
            }
        }

        attemptSend(remaining: retries)
    }

    // Decide if an error should be retried (server 5xx or transport)
    private func shouldRetryForError(_ error: Error) -> Bool {
        let ns = error as NSError
        if let code = ns.userInfo["errorCode"] as? Int, (500...599).contains(code) { return true }
        if (500...599).contains(ns.code) { return true }
        // network connection issues can also be transient — allow a single retry for those
        if (ns.domain == NSURLErrorDomain) { return true }
        return false
    }

    // MARK: Button sending — prefer button service, fallback to pointer when required

    func sendButton(key: String) {
        // public entry — default allow queuing
        sendButton(key: key, allowQueue: true)
    }

    /// Prefer the registered button service; fall back to pointer socket only when needed.
    private func sendButton(key: String, allowQueue: Bool) {
        guard registered else {
            if allowQueue {
                enqueueButtonForRetry(key, prioritizingFront: false)
            }
            return
        }

        if let service = activeInputRemoteService, inputRemotePrimed {
            // attempt send using service. On server errors we will fallback to pointer in handler.
            sendSimple(uri: service.sendButtonURI, payload: ["name": key], retries: 2) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    if self.retryingButtonKey == key { self.retryingButtonKey = nil }
                case .failure(let error):
                    // If server error or missing service, prefer pointer fallback:
                    if self.shouldFallbackToPointer(for: error) {
                        // enqueue and ensure pointer
                        if allowQueue { self.enqueueButtonForRetry(key, prioritizingFront: true) }
                        self.ensurePointerSocket(force: true)
                    } else if allowQueue {
                        // other errors: queue for retry later
                        self.enqueueButtonForRetry(key, prioritizingFront: false)
                    } else {
                        DispatchQueue.main.async { self.lastMessage = "Button failed: \(error.localizedDescription)" }
                    }
                }
            }
            return
        }

        if let pointer = pointerSocket, pointer.isReady {
            pointer.sendButton(key)
            if retryingButtonKey == key { retryingButtonKey = nil }
            return
        }

        // No transport is ready yet — enqueue and kick off registration.
        if allowQueue {
            enqueueButtonForRetry(key, prioritizingFront: false)
            ensureInputRemoteReady() // this will also attempt pointer service if buttons services fail
        }
    }

    // MARK: - Pointer socket helpers

    /// Ensure pointer socket is open (tries pointer services). If `force` -> close existing and reopen.
    private func ensurePointerSocket(force: Bool = false) {
        guard registered else { return }
        if inputRemotePriming && !force { return } // don't race if already priming
        if !force, pointerSocket?.isReady == true { inputRemotePrimed = true; return }

        // If forced, close existing socket first to retry cleanly
        if force {
            pointerSocket?.close()
            pointerSocket = nil
        }

        // Start pointer discovery/connection in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.primePointerService(at: 0, collectedError: nil)
        }
    }

    // primePointerService reuse — attempts pointerServiceCandidates and opens pointer socket
    private func primePointerService(at index: Int, collectedError: Error?) {
        guard registered else { finalizeInputRemotePrime(error: collectedError); return }
        guard !pointerServiceCandidates.isEmpty else { finalizeInputRemotePrime(error: collectedError); return }
        guard index < pointerServiceCandidates.count else { finalizeInputRemotePrime(error: collectedError); return }

        let candidate = pointerServiceCandidates[index]
        sendSimple(uri: candidate.requestURI, payload: [:], retries: 1) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                let urls = self.pointerSocketURLs(from: payload)
                guard !urls.isEmpty else {
                    self.primePointerService(at: index + 1, collectedError: collectedError)
                    return
                }
                self.openPointerSocket(with: urls) { success, error in
                    if success {
                        // pointer ready — mark primed and flush queued buttons
                        self.activeInputRemoteService = nil
                        self.inputRemotePrimed = true
                        self.inputRemotePriming = false
                        self.lastMessage = "Input remote ready (pointer)"
                        self.flushQueuedButtons()
                    } else {
                        self.pointerSocket = nil
                        let aggregatedError = error ?? collectedError
                        self.primePointerService(at: index + 1, collectedError: aggregatedError)
                    }
                }
            case .failure:
                // try next candidate
                self.primePointerService(at: index + 1, collectedError: collectedError)
            }
        }
    }

    private func openPointerSocket(with urls: [URL], completion: @escaping (Bool, Error?) -> Void) {
        guard !urls.isEmpty else {
            completion(false, makeTVError("Pointer socket path missing", code: -15))
            return
        }

        let socket = PointerSocket(host: ip, clientKey: clientKey, allowInsecureLocalTLS: true)
        pointerSocket = socket

        socket.onDisconnect = { [weak self, weak socket] error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let socket, self.pointerSocket === socket else { return }
                self.pointerSocket = nil
                self.inputRemotePrimed = false
                self.activeInputRemoteService = nil
                if let error {
                    if let urlError = error as? URLError, urlError.code == .networkConnectionLost {
                        self.lastMessage = "Pointer connection lost, retrying…"
                    } else {
                        self.lastMessage = "Pointer input disconnected: \(error.localizedDescription)"
                    }
                } else {
                    self.lastMessage = "Pointer connection closed, retrying…"
                }
                // attempt to prime again
                self.ensurePointerSocket(force: true)
            }
        }

        socket.connect(urls: urls) { [weak self, weak socket] success, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if !success, let socket, self.pointerSocket === socket {
                    self.pointerSocket = nil
                }
                completion(success, error)
            }
        }
    }

    // MARK: - Input remote / prime logic (keep but tolerate failures)

    private func ensureInputRemoteReady(force: Bool = false) {
        guard registered else { return }

        if inputRemotePriming { return }
        if !force && inputRemotePrimed { return }
        if !force, pointerSocket?.isReady == true {
            inputRemotePrimed = true
            return
        }

        inputRemotePriming = true

        if force {
            pointerSocket?.close()
            pointerSocket = nil
        }
        activeInputRemoteService = nil

        primeButtonService(at: 0, collectedError: nil)
    }

    private func primeButtonService(at index: Int, collectedError: Error?) {
        guard registered else {
            finalizeInputRemotePrime(error: collectedError)
            return
        }

        var searchIndex = index
        while searchIndex < inputRemoteButtonCandidates.count {
            let service = inputRemoteButtonCandidates[searchIndex]
            if failedButtonServices.contains(service.registerURI) {
                searchIndex += 1
                continue
            }
            let payload = inputRemoteRegisterPayload()
            let currentIndex = searchIndex
            // TRY registration but do not block forever; if failure, mark and continue.
            sendSimple(uri: service.registerURI, payload: payload, retries: 1) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // we successfully registered to a button service — prefer buttons but still keep pointer support
                    self.pointerSocket?.close()
                    self.pointerSocket = nil
                    self.activeInputRemoteService = service
                    self.inputRemotePrimed = true
                    self.inputRemotePriming = false
                    self.lastMessage = "Input remote ready (buttons)"
                    self.flushQueuedButtons()
                case .failure(let error):
                    // mark failure but don't treat as fatal — fall back to pointer
                    self.failedButtonServices.insert(service.registerURI)
                    self.primeButtonService(at: currentIndex + 1, collectedError: error)
                }
            }
            return
        }

        // No button service succeeded — attempt pointer
        primePointerService(at: 0, collectedError: collectedError)
    }

    private func finalizeInputRemotePrime(error: Error?) {
        inputRemotePriming = false
        inputRemotePrimed = false
        activeInputRemoteService = nil
        if let error {
            lastMessage = "Input remote unavailable: \(error.localizedDescription)"
        } else {
            lastMessage = "Input remote unavailable"
        }
    }

    // MARK: Queue helpers

    private func flushQueuedButtons() {
        guard !queuedButtons.isEmpty else { return }
        let pending = queuedButtons
        queuedButtons.removeAll()
        retryingButtonKey = nil
        for key in pending {
            // when flushing, do not allow queueing again (prevent infinite loop)
            sendButton(key: key, allowQueue: false)
        }
    }

    private func enqueueButtonForRetry(_ key: String, prioritizingFront: Bool) {
        queuedButtons.removeAll { $0 == key }
        if prioritizingFront {
            queuedButtons.insert(key, at: 0)
        } else {
            queuedButtons.append(key)
        }
        if queuedButtons.count > 60 {
            // keep a larger window; drop oldest if necessary
            queuedButtons = Array(queuedButtons.suffix(60))
        }
    }

    // MARK: App launching with fallback (unchanged but extended)
    func launchStreamingApp(_ appId: String) {
        attemptLaunch(appId: appId, originalKey: appId, tried: [])
    }

    private func attemptLaunch(appId: String, originalKey: String, tried: Set<String>) {
        DispatchQueue.main.async { self.lastMessage = "Launching \(self.displayName(for: appId))…" }
        sendSimple(uri: "ssap://system.launcher/launch", payload: ["id": appId], retries: 2) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                break
            case .failure(let error):
                let updatedTried = tried.union([appId.lowercased()])
                self.handleLaunchFailure(originalKey: originalKey, tried: updatedTried, error: error)
            }
        }
    }

    private func handleLaunchFailure(originalKey: String, tried: Set<String>, error: Error) {
        let message = error.localizedDescription
        guard isRecoverableLaunchError(message, error: error) else {
            DispatchQueue.main.async {
                self.lastMessage = "\(self.displayName(for: originalKey)) launch failed: \(message)"
            }
            return
        }

        resolveNextAppId(originalKey: originalKey, tried: tried) { [weak self] nextId in
            guard let self else { return }
            guard let nextId else {
                DispatchQueue.main.async {
                    self.lastMessage = "\(self.displayName(for: originalKey)) launch failed: \(message)"
                }
                return
            }
            DispatchQueue.main.async {
                self.lastMessage = "Retrying \(self.displayName(for: originalKey)) as \(self.displayName(for: nextId))…"
            }
            self.attemptLaunch(appId: nextId, originalKey: originalKey, tried: tried)
        }
    }

    private func displayName(for appId: String) -> String {
        let key = appId.lowercased()
        return streamingAppDisplayNames[key] ?? appId
    }

    private func isRecoverableLaunchError(_ message: String, error: Error) -> Bool {
        let lower = message.lowercased()
        if lower.contains("no such app") || lower.contains("no such application") || lower.contains("not installed") || lower.contains("no such service") || lower.contains("not exist") { return true }
        if lower.contains("internal server error") || lower.contains("internal error") || lower.contains("application error") || lower.contains("500") || lower.contains("404") { return true }
        let nsError = error as NSError
        if (400...599).contains(nsError.code) { return true }
        if let code = nsError.userInfo["errorCode"] as? Int, (400...599).contains(code) { return true }
        return false
    }

    // Helper: find alternate IDs to retry
    private func resolveNextAppId(originalKey: String, tried: Set<String>, completion: @escaping (String?) -> Void) {
        if let staticId = nextStaticAppId(originalKey: originalKey, tried: tried) {
            completion(staticId)
            return
        }

        let keywords = keywordGroups(for: originalKey)

        if let cached = searchInstalledApps(using: keywords, tried: tried) {
            completion(cached)
            return
        }

        fetchInstalledApps(force: false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                completion(self.searchInstalledApps(using: keywords, tried: tried))
            case .failure(let error):
                DispatchQueue.main.async {
                    self.lastMessage = "Couldn’t fetch installed apps: \(error.localizedDescription)"
                }
                completion(nil)
            }
        }
    }

    private func nextStaticAppId(originalKey: String, tried: Set<String>) -> String? {
        let lower = originalKey.lowercased()
        if let fallback = streamingAppFallbacks[lower] {
            for alt in fallback.alternates where !tried.contains(alt.lowercased()) {
                return alt
            }
        }
        for (key, fallback) in streamingAppFallbacks {
            if tried.contains(key) { continue }
            for group in fallback.keywordGroups {
                if group.allSatisfy({ lower.contains($0) }) {
                    return key
                }
            }
        }
        return nil
    }

    private func keywordGroups(for key: String) -> [[String]] {
        var groups: [[String]] = []
        if let fallback = streamingAppFallbacks[key.lowercased()] {
            groups.append(contentsOf: fallback.keywordGroups)
        }
        if let display = streamingAppDisplayNames[key.lowercased()] {
            let tokens = normalizedKeywords(from: display)
            if !tokens.isEmpty { groups.append(tokens) }
        }
        let direct = normalizedKeywords(from: key)
        if !direct.isEmpty { groups.append(direct) }
        return groups
    }

    private func normalizedKeywords(from text: String) -> [String] {
        return text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private func searchInstalledApps(using keywordGroups: [[String]], tried: Set<String>) -> String? {
        guard !installedApps.isEmpty else { return nil }
        for group in keywordGroups where !group.isEmpty {
            if let match = installedApps.first(where: { app in
                guard !tried.contains(app.id.lowercased()) else { return false }
                let haystack = "\(app.title) \(app.id)".lowercased()
                return group.allSatisfy { haystack.contains($0) }
            }) {
                return match.id
            }
        }
        return nil
    }

    private func fetchInstalledApps(force: Bool,
                                    completion: @escaping (Result<[TVApp], Error>) -> Void) {
        DispatchQueue.main.async {
            if !force,
               let last = self.lastAppFetchDate,
               Date().timeIntervalSince(last) < 30,
               !self.installedApps.isEmpty {
                completion(.success(self.installedApps))
                return
            }

            guard self.registered else {
                completion(.failure(self.makeTVError("TV not registered", code: -16)))
                return
            }

            self.appFetchCallbacks.append(completion)
            if self.appFetchCallbacks.count > 1 { return }

            self.sendSimple(uri: "ssap://com.webos.applicationManager/listApps",
                            payload: [:],
                            retries: 1) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let payload):
                    let apps = self.parseInstalledApps(from: payload)
                    self.installedApps = apps
                    self.lastAppFetchDate = Date()
                    let callbacks = self.appFetchCallbacks
                    self.appFetchCallbacks.removeAll()
                    callbacks.forEach { $0(.success(apps)) }
                case .failure(let error):
                    let callbacks = self.appFetchCallbacks
                    self.appFetchCallbacks.removeAll()
                    callbacks.forEach { $0(.failure(error)) }
                }
            }
        }
    }

    private func parseInstalledApps(from payload: [String: Any]) -> [TVApp] {
        guard let entries = payload["apps"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var parsed: [TVApp] = []
        for entry in entries {
            guard let idRaw = entry["id"] as? String else { continue }
            let id = idRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if !seen.insert(id.lowercased()).inserted { continue }
            let title = (entry["title"] as? String ??
                         entry["name"] as? String ??
                         entry["appName"] as? String ??
                         id).trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.append(TVApp(id: id, title: title))
        }
        return parsed
    }

    private func prefetchInstalledApps() {
        fetchInstalledApps(force: true) { _ in }
    }

    // MARK: Socket open / register / pairing (unchanged core logic)

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
        failedButtonServices.removeAll()
        pointerSocket?.close()
        pointerSocket = nil
        activeInputRemoteService = nil
        installedApps.removeAll()
        lastAppFetchDate = nil
        cancelAppFetches(reason: "Disconnected")
        cancelAllPendingRequests(message: "Disconnected")
        if connectCompletion != nil { completeConnect(false, "Disconnected") }
        DispatchQueue.main.async { self.isConnected = false; self.onDisconnect?() }
    }

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

    // MARK: Message handling (partial reuse)
    private func handleSocketMessage(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let msg):
            switch msg {
            case .string(let s):
                DispatchQueue.main.async { self.processJSONMessage(s) }
            case .data:
                break
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
                self.failedButtonServices.removeAll()
                self.pointerSocket?.close()
                self.pointerSocket = nil
                self.activeInputRemoteService = nil
                self.installedApps.removeAll()
                self.lastAppFetchDate = nil
                self.cancelAppFetches(reason: "Socket error")
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
            if let key = payload?["client-key"] as? String { Self.savedClientKey = key; self.clientKey = key }
            DispatchQueue.main.async {
                let firstRegistration = !self.registered
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                if firstRegistration {
                    self.onConnect?()
                    self.completeConnect(true, "Registered ✓")
                    // proactively prime input remote services so buttons are ready immediately
                    self.ensureInputRemoteReady(force: true)
                    self.prefetchInstalledApps()
                }
            }
            return

        case "response":
            handleResponse(id: id, payload: payload, dict: dict); return
        case "error":
            handleError(id: id, payload: payload, dict: dict); return
        default: break
        }

        // Handle pairing prompts that include client-key
        if let payload,
           let pairingType = payload["pairingType"] as? String,
           pairingType == "PROMPT",
           let key = payload["client-key"] as? String {
            Self.savedClientKey = key
            self.clientKey = key
            DispatchQueue.main.async {
                let firstRegistration = !self.registered
                self.registered = true
                self.isConnected = true
                self.lastMessage = "Registered ✓"
                if firstRegistration {
                    self.onConnect?()
                    self.completeConnect(true, "Registered ✓")
                    self.ensureInputRemoteReady(force: true)
                    self.prefetchInstalledApps()
                }
            }
        }
    }

    // MARK: Error / response helpers (kept similar)
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
            if !handled { DispatchQueue.main.async { self.lastMessage = "Command failed: \(message)" } }
        }
    }

    private func handleError(id: String?, payload: [String: Any]?, dict: [String: Any]) {
        let message = extractErrorMessage(dict: dict, payload: payload)
        var handled = false
        if let id {
            let error = makeTVError(message, code: -12, payload: payload)
            handled = completeRequest(id: id, result: .failure(error))
        }
        if !handled && !registered { failEarly("TV error: \(message)") }
        else if !handled { DispatchQueue.main.async { self.lastMessage = "TV error: \(message)" } }
        if isGestureTimeout(message) { handleGestureTimeout() }
    }

    @discardableResult
    private func completeRequest(id: String, result: Result<[String: Any], Error>) -> Bool {
        guard let handler = pendingResponses.removeValue(forKey: id) else { return false }
        DispatchQueue.main.async { handler(result) }
        return true
    }

    private func extractErrorMessage(dict: [String: Any], payload: [String: Any]?) -> String {
        if let payload, let text = payload["errorText"] as? String, !text.isEmpty { return text }
        if let payload, let message = payload["message"] as? String, !message.isEmpty { return message }
        if let error = dict["error"] as? String, !error.isEmpty { return error }
        if let payload, let code = payload["errorCode"] { return "\(code)" }
        return "Unknown error"
    }

    private func makeTVError(_ message: String, code: Int = -10, payload: [String: Any]? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let payload, let errorCode = payload["errorCode"] { userInfo["errorCode"] = errorCode }
        return NSError(domain: "WebOSTV", code: code, userInfo: userInfo)
    }

    private func isGestureTimeout(_ message: String) -> Bool { message.lowercased().contains("gesture gate timed out") }

    private func isServiceMissing(_ message: String, error: Error) -> Bool {
        let lower = message.lowercased()
        if lower.contains("no such service") || lower.contains("service not found") { return true }
        if lower.contains("invalid request") && lower.contains("input") { return true }
        if lower.contains("404") { return true }
        let ns = error as NSError
        if let code = ns.userInfo["errorCode"] as? Int, code == 404 { return true }
        if let codeString = ns.userInfo["errorCode"] as? String, codeString == "404" { return true }
        return false
    }

    private func shouldFallbackToPointer(for error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("internal server error") || lower.contains("500") || lower.contains("application error") { return true }
        let ns = error as NSError
        if let code = ns.userInfo["errorCode"] as? Int, (500...599).contains(code) { return true }
        if (500...599).contains(ns.code) { return true }
        return false
    }

    private func handleGestureTimeout() {
        inputRemotePrimed = false
        ensureInputRemoteReady(force: true)
    }

    // MARK: Utilities: cancel, complete connect, ping, etc.
    private func cancelAllPendingRequests(message: String) {
        guard !pendingResponses.isEmpty else { return }
        let handlers = pendingResponses
        pendingResponses.removeAll()
        let error = makeTVError(message, code: -14)
        for handler in handlers.values {
            DispatchQueue.main.async { handler(.failure(error)) }
        }
    }

    private func cancelAppFetches(reason: String) {
        guard !appFetchCallbacks.isEmpty else { return }
        let callbacks = appFetchCallbacks
        appFetchCallbacks.removeAll()
        let error = makeTVError(reason, code: -18)
        callbacks.forEach { $0(.failure(error)) }
    }

    private func completeConnect(_ ok: Bool, _ message: String) {
        let comp = connectCompletion
        connectCompletion = nil
        DispatchQueue.main.async {
            comp?(ok, message)
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
            self.failedButtonServices.removeAll()
            self.pointerSocket?.close()
            self.pointerSocket = nil
            self.activeInputRemoteService = nil
            self.installedApps.removeAll()
            self.lastAppFetchDate = nil
            self.cancelAppFetches(reason: reason)
            self.cancelAllPendingRequests(message: reason)
            self.onDisconnect?()
            self.lastMessage = reason
            self.completeConnect(false, reason)
        }
    }

    // Add this inside WebOSTV class

    /// Build pointer socket URLs from the payload returned by pointer service.
    private func pointerSocketURLs(from payload: [String: Any]) -> [URL] {
        var rawEntries: [String] = []

        if let secure = payload["socketPathSecure"] as? String { rawEntries.append(secure) }
        if let path = payload["socketPath"] as? String { rawEntries.append(path) }

        if let list = payload["socketPathList"] as? [String] {
            rawEntries.append(contentsOf: list)
        } else if let nestedList = payload["socketPathList"] as? [[String: Any]] {
            for entry in nestedList {
                if let uri = entry["uri"] as? String { rawEntries.append(uri) }
                if let path = entry["path"] as? String { rawEntries.append(path) }
            }
        }

        if let socketPaths = payload["socketPaths"] as? [String] {
            rawEntries.append(contentsOf: socketPaths)
        }
        if let socket = payload["socket"] as? String {
            rawEntries.append(socket)
        }

        // If no explicit paths, TV may provide address/port
        if rawEntries.isEmpty, let address = payload["address"] as? String {
            var ports: [Int] = []
            if let port = payload["port"] as? Int { ports.append(port) }
            else if let ps = payload["port"] as? String, let p = Int(ps) { ports.append(p) }
            if ports.isEmpty { ports = [3001, 3000] }
            for scheme in ["wss", "ws"] {
                for port in ports {
                    if let url = URL(string: "\(scheme)://\(address):\(port)") {
                        rawEntries.append(url.absoluteString)
                    }
                }
            }
        }

        var urls: [URL] = []
        for entry in rawEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // If an absolute url, keep it. Else try building with ip & common ports
            if let url = URL(string: trimmed), url.scheme != nil {
                urls.append(url)
            } else {
                var t = trimmed
                if t.hasPrefix("//") { t.removeFirst(2) }
                if !t.hasPrefix("/") { t = "/\(t)" }
                for scheme in ["wss", "ws"] {
                    for port in [3001, 3000] {
                        if let url = URL(string: "\(scheme)://\(ip):\(port)\(t)") {
                            urls.append(url)
                        }
                    }
                }
            }
        }

        // dedupe
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Register payload for input remote registration (uses saved client key if present)
    private func inputRemoteRegisterPayload() -> [String: Any] {
        if let key = self.clientKey, !key.isEmpty {
            return ["client-key": key]
        }
        return [:]
    }// Call this from PairTVView after connect(...) succeeds.
    // It will attempt several common URIs and scan the reply for MAC-like values.
    func fetchMacAddress(completion: @escaping (String?) -> Void) {
        // If not registered, return quickly
        guard registered else {
            completion(nil)
            return
        }

        // Candidate URIs to query for device/network info (various TVs expose differing endpoints)
        let candidates = [
            "ssap://com.webos.service.tv.system/getDeviceInfo",
            "ssap://com.webos.service.system/getDeviceInfo",
            "ssap://system/getDeviceInfo",
            "ssap://com.webos.service.network/getNetworkInfo",
            "ssap://com.webos.service.network/getMacAddress",
            "ssap://com.webos.service.tv.system/getWol", // sometimes returns mac in payload
            "ssap://com.webos.service.tv.info/getDeviceInfo"
        ]

        // Helper: try URIs sequentially until we find a MAC
        func tryNext(_ index: Int) {
            if index >= candidates.count {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let uri = candidates[index]

            // sendSimple already handles registration & retries
            sendSimple(uri: uri, payload: [:], retries: 1) { [weak self] result in
                guard let self = self else { DispatchQueue.main.async { completion(nil) }; return }

                switch result {
                case .success(let payload):
                    // Search payload for mac-like strings
                    if let found = self.extractMacFromPayload(payload) {
                        DispatchQueue.main.async { completion(found) }
                        return
                    }
                    // sometimes the payload wraps nested dictionaries/arrays
                    if let found = self.deepSearchForMac(in: payload) {
                        DispatchQueue.main.async { completion(found) }
                        return
                    }
                    // try next candidate
                    tryNext(index + 1)

                case .failure(_):
                    // try next candidate on any failure
                    tryNext(index + 1)
                }
            }
        }

        tryNext(0)
    }

    // MARK: - Helpers to extract MAC from returned payloads

    private func extractMacFromPayload(_ payload: [String: Any]) -> String? {
        // Common keys that might directly contain a mac
        let keys = ["mac", "macAddress", "ethernetMac", "wifiMac", "bssid", "address"]
        for k in keys {
            if let v = payload[k] as? String, let normalized = normalizeMac(v) {
                return normalized
            }
            if let vnum = payload[k] as? NSNumber {
                // unlikely, but convert to string
                if let normalized = normalizeMac("\(vnum)") { return normalized }
            }
        }

        // Sometimes the payload has "device" sub-dict
        if let device = payload["device"] as? [String: Any] {
            if let mac = extractMacFromPayload(device) { return mac }
        }
        if let network = payload["network"] as? [String: Any] {
            if let mac = extractMacFromPayload(network) { return mac }
        }

        // Look for any string values containing mac-like pattern in the top-level payload
        for (_, value) in payload {
            if let s = value as? String, let normalized = normalizeMac(s) {
                return normalized
            }
        }

        return nil
    }

    private func deepSearchForMac(in any: Any) -> String? {
        // recursively scan dictionaries and arrays for MAC-like strings
        if let dict = any as? [String: Any] {
            if let found = extractMacFromPayload(dict) { return found }
            for (_, v) in dict {
                if let found = deepSearchForMac(in: v) { return found }
            }
        } else if let arr = any as? [Any] {
            for item in arr {
                if let found = deepSearchForMac(in: item) { return found }
            }
        } else if let s = any as? String {
            return normalizeMac(s)
        }
        return nil
    }

    private func normalizeMac(_ raw: String) -> String? {
        // find any 12-hex or 6 pairs patterns in the string
        // Accepts formats: AABBCCDDEEFF, AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, AA.BB.CC.DD.EE.FF
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // regex to find 6 hex pairs separators or 12 hex digits
        let patterns = [
            "([0-9a-f]{2}[:\\-\\.]){5}[0-9a-f]{2}",   // AA:BB:... or AA-BB-... or AA.BB...
            "[0-9a-f]{12}"                            // AABBCCDDEEFF
        ]

        for pat in patterns {
            if let range = candidate.range(of: pat, options: .regularExpression) {
                let match = String(candidate[range])
                // remove separators and uppercase with colons
                let hexOnly = match.replacingOccurrences(of: "[:\\-\\.]", with: "", options: .regularExpression)
                guard hexOnly.count == 12 else { continue }
                var outParts: [String] = []
                var i = hexOnly.startIndex
                for _ in 0..<6 {
                    let j = hexOnly.index(i, offsetBy: 2)
                    outParts.append(String(hexOnly[i..<j]).uppercased())
                    i = j
                }
                return outParts.joined(separator: ":")
            }
        }

        return nil
    }


    // MARK: saved properties
    static var savedIPKey: String { "LGRemoteMVP.lastIP" }
    static var savedMACKey: String { "LGRemoteMVP.lastMAC" }

    // MARK: - End
}

