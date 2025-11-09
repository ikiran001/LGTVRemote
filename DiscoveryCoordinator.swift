import Foundation
import Combine

/// Runs Bonjour + SSDP + LAN sweep in parallel and publishes a merged, de-duplicated device list.
final class DiscoveryCoordinator: ObservableObject {

    @Published private(set) var devices: [SSDPDevice] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var methodHint: String = "Idle"

    private let bonjour = BonjourDiscovery()
    private let ssdp = SSDPDiscovery()
    private let lan = LANDiscovery()

    private var bag = Set<AnyCancellable>()
    private let mergeQueue = DispatchQueue(label: "discovery.merge.queue")

    init() {
        bonjour.$devices
            .combineLatest(ssdp.$devices, lan.$devices)
            .receive(on: mergeQueue)
            .sink { [weak self] b, s, l in
                self?.publishMerged(b + s + l)
            }
            .store(in: &bag)
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        methodHint = "Bonjour + SSDP + LAN"
        devices.removeAll()

        bonjour.start()
        ssdp.scan(timeout: 4.0)

        lan.scan(timeoutPerHost: 0.45, maxConcurrent: 12) { [weak self] in
            DispatchQueue.main.async { self?.isScanning = false }
        }

        // Stop Bonjour after a short window to conserve resources
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.bonjour.stop()
        }
    }

    func cancel() {
        bonjour.stop()
        ssdp.cancel()
        lan.cancel()
        isScanning = false
        methodHint = "Idle"
    }

    private func publishMerged(_ list: [SSDPDevice]) {
        var byIP: [String: SSDPDevice] = [:]
        for d in list {
            if let existing = byIP[d.ip] {
                // prefer entry with friendlyName or bonjour server tag
                let preferD = (d.friendlyName?.isEmpty == false) || (d.server == "bonjour")
                byIP[d.ip] = preferD ? d : existing
            } else {
                byIP[d.ip] = d
            }
        }
        let merged = Array(byIP.values).sorted { $0.ip < $1.ip }
        DispatchQueue.main.async { self.devices = merged }
    }
}

