import Foundation
import Network
import Combine

/// mDNS/Bonjour discovery for common LG / webOS service types.
/// Uses separate NetServiceBrowser instances so all types can be browsed in parallel.
final class BonjourDiscovery: NSObject, ObservableObject {

    @Published private(set) var devices: [SSDPDevice] = []

    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private(set) var isRunning = false

    /// Service types that webOS TVs (and some LG devices) commonly advertise.
    private let serviceTypes: [String] = [
        "_webostv._tcp.",
        "_lg-smart-device._tcp.",
        "_mediaremotetv._tcp."
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        devices.removeAll()
        services.removeAll()
        browsers.removeAll()

        for type in serviceTypes {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "")   // browse default domain
            browsers.append(b)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for b in browsers { b.stop() }
        browsers.removeAll()
        services.removeAll()
    }

    private func resolve(_ service: NetService) {
        service.delegate = self
        service.resolve(withTimeout: 3.0)
    }

    private func addOrUpdate(ip: String, name: String?) {
        DispatchQueue.main.async {
            if let idx = self.devices.firstIndex(where: { $0.ip == ip }) {
                // Prefer to keep/attach a friendly name if we have one
                var existing = self.devices[idx]
                let friendly = name ?? existing.friendlyName
                existing = SSDPDevice(ip: existing.ip,
                                      usn: existing.usn,
                                      server: "bonjour",
                                      location: existing.location,
                                      friendlyName: friendly,
                                      modelName: existing.modelName)
                self.devices[idx] = existing
            } else {
                self.devices.append(
                    SSDPDevice(ip: ip,
                               usn: nil,
                               server: "bonjour",
                               location: nil,
                               friendlyName: name,
                               modelName: nil)
                )
            }
        }
    }
}

// MARK: - NetServiceBrowserDelegate
extension BonjourDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        services.append(service)
        resolve(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        // Optional: prune if you like. We leave previously discovered entries in the list.
    }
}

// MARK: - NetServiceDelegate
extension BonjourDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let dataList = sender.addresses else { return }

        for data in dataList {
            data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let sa = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    // IPv4
                    var sin = sockaddr_in()
                    memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
                    var addr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var a = sin.sin_addr
                    inet_ntop(AF_INET, &a, &addr, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: addr)
                    self.addOrUpdate(ip: ip, name: sender.name)
                }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        // Ignore individual resolve failures; others will still come through.
    }
}

