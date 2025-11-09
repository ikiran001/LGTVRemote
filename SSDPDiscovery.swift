import Foundation
import Combine
import Network

public struct SSDPDevice: Identifiable, Hashable {
    public let id = UUID()
    public let ip: String
    public let usn: String?
    public let server: String?
    public let location: URL?
    public let friendlyName: String?
    public let modelName: String?
}

final class SSDPDiscovery: ObservableObject {
    @Published private(set) var devices: [SSDPDevice] = []

    private let queue = DispatchQueue(label: "ssdp.discovery.queue")
    private var connection: NWConnection?
    private var isScanning = false
    private var stopTime: DispatchTime = .now()

    /// Start a short SSDP scan. Works on iOS 14+ without any special parameter flags.
    func scan(timeout: TimeInterval = 4.0) {
        guard !isScanning else { return }
        isScanning = true
        stopTime = .now() + timeout
        DispatchQueue.main.async { self.devices.removeAll() }

        // IMPORTANT: Make sure Info.plist has NSLocalNetworkUsageDescription.
        LocalNetworkAuthorizer.nudgeLocalNetworkPermission()

        // Simple UDP connection to the SSDP multicast address/port
        let host = NWEndpoint.Host("239.255.255.250")
        let port = NWEndpoint.Port(rawValue: 1900)!
        let params = NWParameters.udp

        let conn = NWConnection(host: host, port: port, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Send a few queries (basic + LG/webOS)
                self.sendMSearch(st: "ssdp:all")
                self.sendMSearch(st: "upnp:rootdevice")
                self.sendMSearch(st: "urn:lge-com:service:webos-second-screen:1")

                // Receive replies until timeout
                self.receiveLoop()

                self.queue.asyncAfter(deadline: self.stopTime) { [weak self] in
                    self?.finish()
                }

            case .failed(let error):
                print("SSDP: connection failed: \(error.localizedDescription)")
                self.finish()
            case .cancelled:
                self.finish()
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    func cancel() { finish() }

    // MARK: - Internals

    private func finish() {
        guard isScanning else { return }
        isScanning = false
        connection?.cancel()
        connection = nil
    }

    private func sendMSearch(st: String) {
        guard let conn = connection else { return }
        let lines = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: \(st)",
            "USER-AGENT: iOS LGRemoteMVP",
            "", ""
        ]
        if let data = lines.joined(separator: "\r\n").data(using: .utf8) {
            // Send twice to improve chances
            conn.send(content: data, completion: .contentProcessed { _ in })
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, error == nil, let text = String(data: data, encoding: .utf8) {
                self.handleResponse(text: text)
            }
            if self.isScanning { self.receiveLoop() }
        }
    }

    private func handleResponse(text: String) {
        let headers = parseHeaders(text)
        guard
            let locStr = headers["location"],
            let url = URL(string: locStr),
            let host = url.host,
            isIPv4(host)
        else { return }

        let serverLower = headers["server"]?.lowercased() ?? ""
        let usnLower = headers["usn"]?.lowercased() ?? ""
        let stLower = headers["st"]?.lowercased() ?? ""

        // Likely LG/webOS or TV renderer
        let looksLikeTV =
            serverLower.contains("webos") ||
            serverLower.contains("lge") ||
            usnLower.contains("lge") ||
            stLower.contains("webos") ||
            stLower.contains("mediarenderer")

        guard looksLikeTV else { return }

        // Optionally fetch device description (friendly/model)
        fetchDeviceDescription(from: url) { [weak self] friendly, model in
            guard let self else { return }
            let dev = SSDPDevice(
                ip: host,
                usn: headers["usn"],
                server: headers["server"],
                location: url,
                friendlyName: friendly,
                modelName: model
            )
            self.insertOrUpdate(dev)
        }
    }

    private func parseHeaders(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key.lowercased()] = val }
        }
        return out
    }

    private func fetchDeviceDescription(from url: URL,
                                        completion: @escaping (String?, String?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let xml = String(data: data, encoding: .utf8) else {
                completion(nil, nil); return
            }
            func extract(_ tag: String) -> String? {
                guard let s = xml.range(of: "<\(tag)>"),
                      let e = xml.range(of: "</\(tag)>", range: s.upperBound..<xml.endIndex) else { return nil }
                return String(xml[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            completion(extract("friendlyName"), extract("modelName"))
        }.resume()
    }

    private func insertOrUpdate(_ device: SSDPDevice) {
        DispatchQueue.main.async {
            if let idx = self.devices.firstIndex(where: { $0.ip == device.ip }) {
                self.devices[idx] = device
            } else {
                self.devices.append(device)
            }
        }
    }

    private func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            if let v = Int(p), v >= 0 && v <= 255 { return true }
            return false
        }
    }
}

