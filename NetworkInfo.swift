import Foundation
import SystemConfiguration.CaptiveNetwork
import Network

enum NetworkInfo {
    /// Returns the primary IPv4 address for Wi-Fi (en0) or cellular as fallback.
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        // Prefer en0 (Wi-Fi), then anything IPv4 that’s up and not loopback.
        var candidates: [String: String] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let addrFamily = ifa.ifa_addr.pointee.sa_family
            guard addrFamily == sa_family_t(AF_INET) else { continue } // IPv4 only

            let name = String(cString: ifa.ifa_name)
            var addr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var sa = ifa.ifa_addr.pointee
            let result = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                &addr, socklen_t(addr.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard result == 0 else { continue }
            let ip = String(cString: addr)

            // Skip loopback
            if ip.hasPrefix("127.") { continue }

            candidates[name] = ip
        }

        if let wifi = candidates["en0"] { address = wifi }
        else { address = candidates.values.first }

        return address
    }

    /// Requires the "Access WiFi Information" entitlement on iOS.
    /// Without entitlement this usually returns nil on device.
    static func wifiSSIDAndBSSID() -> (ssid: String, bssid: String)? {
        guard let ifs = CNCopySupportedInterfaces() as? [String] else { return nil }
        for ifname in ifs {
            if let dict = CNCopyCurrentNetworkInfo(ifname as CFString) as? [String: Any],
               let ssid = dict[kCNNetworkInfoKeySSID as String] as? String,
               let bssid = dict[kCNNetworkInfoKeyBSSID as String] as? String {
                return (ssid, bssid) // bssid = router’s MAC (AP), not your TV
            }
        }
        return nil
    }
}

