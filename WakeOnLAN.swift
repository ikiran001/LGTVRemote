import Foundation

/// Lightweight, dependency-free Wake-on-LAN sender for iOS/macOS.
/// Uses BSD sockets to support broadcast (SO_BROADCAST).
enum WakeOnLAN {

    // MARK: - Public API

    struct Options {
        /// How many times to send the full set of packets (bursting improves reliability).
        var bursts: Int = 3
        /// Gap between bursts in milliseconds.
        var burstGapMs: useconds_t = 80
        /// UDP ports to try (9 and 7 are common for WoL).
        var ports: [UInt16] = [9, 7]
        /// Also try unicast to ipHint (some firmwares accept it).
        var alsoUnicast: Bool = true

        public init(bursts: Int = 3, burstGapMs: useconds_t = 80, ports: [UInt16] = [9, 7], alsoUnicast: Bool = true) {
            self.bursts = bursts
            self.burstGapMs = burstGapMs
            self.ports = ports
            self.alsoUnicast = alsoUnicast
        }
    }

    /// Wake a device by MAC address. Optionally provide `ipHint` (last known TV IP) to add directed broadcast + unicast.
    /// Calls `completion(true)` if at least one packet send reported success.
    static func wake(
        macAddress: String,
        ipHint: String? = nil,
        options: Options = Options(),
        completion: ((Bool) -> Void)? = nil
    ) {
        let normalizedMac = macAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let macData = macToData(normalizedMac) else {
            completion?(false)
            return
        }
        let magic = buildMagicPacket(macData)
        let targets = buildTargets(ipHint: ipHint, ports: options.ports, alsoUnicast: options.alsoUnicast)

        // Fire on a background thread to avoid blocking UI.
        DispatchQueue.global(qos: .utility).async {
            var anySuccess = false
            for _ in 0..<max(1, options.bursts) {
                for t in targets {
                    if send(magic, to: t.host, port: t.port) {
                        anySuccess = true
                    }
                }
                if options.burstGapMs > 0 {
                    usleep(options.burstGapMs * 1000)
                }
            }
            completion?(anySuccess)
        }
    }

    /// Back-compat shim with your old signature.
    static func sendMagicPacket(macAddress: String) {
        wake(macAddress: macAddress, ipHint: nil, options: Options(), completion: nil)
    }

    // MARK: - Internals

    /// Accepts:
    /// - `AA:BB:CC:DD:EE:FF`
    /// - `AA-BB-CC-DD-EE-FF`
    /// - `AA.BB.CC.DD.EE.FF`
    /// - `AABBCCDDEEFF`
    private static func macToData(_ mac: String) -> Data? {
        let trimmed = mac
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let separators: CharacterSet = CharacterSet(charactersIn: ":-.")
        let parts: [String]
        if trimmed.rangeOfCharacter(from: separators) != nil {
            parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
            guard parts.count == 6 else { return nil }
            let bytes = parts.compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 6 else { return nil }
            return Data(bytes)
        } else {
            // Plain 12-hex chars
            guard trimmed.count == 12 else { return nil }
            var bytes = [UInt8]()
            var i = trimmed.startIndex
            for _ in 0..<6 {
                let j = trimmed.index(i, offsetBy: 2)
                let byteStr = String(trimmed[i..<j])
                guard let b = UInt8(byteStr, radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            return Data(bytes)
        }
    }

    private static func buildMagicPacket(_ mac: Data) -> Data {
        var d = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { d.append(mac) }
        return d
    }

    private struct Target: Hashable {
        let host: String
        let port: UInt16
    }

    private static func buildTargets(ipHint: String?, ports: [UInt16], alsoUnicast: Bool) -> [Target] {
        var set = Set<Target>()

        // 1) Global broadcast
        for p in ports { set.insert(Target(host: "255.255.255.255", port: p)) }

        // 2) Directed broadcast (/24 from ipHint, if available)
        if let ip = ipHint, let bcast = directedBroadcast(ip) {
            for p in ports { set.insert(Target(host: bcast, port: p)) }
        }

        // 3) Unicast (some routers/firmware accept)
        if alsoUnicast, let ip = ipHint {
            for p in ports { set.insert(Target(host: ip, port: p)) }
        }

        return Array(set)
    }

    /// Assumes /24 for simplicity (most home LANs). Example: 192.168.1.42 => 192.168.1.255
    private static func directedBroadcast(_ ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    // MARK: - BSD UDP sender with SO_BROADCAST
    @discardableResult
    private static func send(_ data: Data, to host: String, port: UInt16) -> Bool {
        return host.withCString { cHost -> Bool in
            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            if sock < 0 { return false }

            defer { close(sock) }

            // Enable broadcast
            var yes: Int32 = 1
            if setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) != 0 {
                // Not fatal for unicast, but needed for broadcast; continue anyway.
            }

            // Build IPv4 addr
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            guard inet_aton(cHost, &addr.sin_addr) != 0 else {
                return false
            }

            let sent = data.withUnsafeBytes { ptr -> ssize_t in
                let p = ptr.bindMemory(to: UInt8.self).baseAddress!
                return withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(sock, p, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.stride))
                    }
                }
            }

            return sent == data.count
        }
    }
}

