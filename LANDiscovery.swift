import Foundation
import Combine
import Darwin // sockets + poll()

/// Quiet /24 sweep that probes only TCP (no Network.framework):
/// tries port 3001 (wss) first, then 3000 (ws). Adds any responders as candidates.
final class LANDiscovery: ObservableObject {

    @Published private(set) var devices: [SSDPDevice] = []
    @Published private(set) var isScanning: Bool = false

    private let work = DispatchQueue(label: "lan.discovery.posix.queue", qos: .utility)

    /// Kick off a sweep. Non-blocking; results are published to `devices`.
    func scan(timeoutPerHost: TimeInterval = 0.40, maxConcurrent: Int = 12, completion: (() -> Void)? = nil) {
        guard !isScanning else { return }
        isScanning = true
        devices.removeAll()

        guard let base = Self.localIPv4Base24() else {
            isScanning = false
            completion?()
            return
        }

        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: maxConcurrent)

        for last in 1...254 {
            let ip = "\(base).\(last)"
            semaphore.wait()
            group.enter()

            work.async {
                // Quiet POSIX socket probe: 3001 first, then 3000
                let ok = Self.tcpConnectQuick(ip: ip, port: 3001, timeout: timeoutPerHost)
                      || Self.tcpConnectQuick(ip: ip, port: 3000, timeout: timeoutPerHost)

                if ok { self.add(ip) }

                semaphore.signal()
                group.leave()
            }
        }

        group.notify(queue: work) {
            DispatchQueue.main.async {
                self.isScanning = false
                completion?()
            }
        }
    }

    func cancel() { isScanning = false }

    // MARK: - Publish helpers

    private func add(_ ip: String) {
        DispatchQueue.main.async {
            if self.devices.contains(where: { $0.ip == ip }) { return }
            self.devices.append(
                SSDPDevice(ip: ip, usn: nil, server: "tcp-scan", location: nil, friendlyName: nil, modelName: nil)
            )
        }
    }

    // MARK: - Local IP (/24 base)

    /// Returns "A.B.C" for A.B.C.X if Wi-Fi IPv4 is present (prefers en0).
    private static func localIPv4Base24() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidate: String?

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr?.pointee, sa.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name != "en0" { continue } // prefer Wi-Fi

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa.ifa_addr, socklen_t(sa.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidate = String(cString: host)
                break
            }
        }

        guard let ip = candidate else { return nil }
        let parts = ip.split(separator: "."); guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    // MARK: - Quiet TCP checker (non-blocking; uses poll())

    /// Non-blocking connect with timeout; no Network.framework so the console stays clean.
    private static func tcpConnectQuick(ip: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var inetAddr = in_addr()
        guard ip.withCString({ inet_pton(AF_INET, $0, &inetAddr) }) == 1 else { return false }

        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = inetAddr

        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if sock < 0 { return false }

        // Non-blocking
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        // No SIGPIPE on failures
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))

        // Begin connect
        var saddr = sockaddr()
        memcpy(&saddr, &sa, MemoryLayout<sockaddr_in>.size)
        let res = withUnsafePointer(to: &saddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if res == 0 { close(sock); return true }
        if errno != EINPROGRESS { close(sock); return false }

        // Wait for writability or timeout
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(max(1, Int(timeout * 1000)))
        let pr = poll(&pfd, 1, timeoutMs)
        if pr <= 0 { close(sock); return false }

        // Confirm with SO_ERROR
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout.size(ofValue: err))
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
        close(sock)
        return err == 0
    }
}

