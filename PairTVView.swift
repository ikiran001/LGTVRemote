import SwiftUI

struct PairTVView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SavedTVStore

    @StateObject private var discovery = DiscoveryCoordinator()

    // Inputs
    @State private var brand: String = "LG"
    @State private var name: String = "Living Room"
    @State private var ip: String = ""
    @State private var mac: String = ""

    // UI state
    @State private var isPairing = false
    @State private var pairStatus: String = ""
    @State private var autoMacStatus: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // ── Discovery ────────────────────────────────────────────────────
                Section(header: Text("Search / Discover"),
                        footer: Text("Runs Bonjour + SSDP + ping/TCP sweep in parallel. Make sure iPhone and TV are on the same Wi-Fi (no guest/AP isolation).")
                            .font(.caption).foregroundStyle(.secondary)) {

                    Button {
                        autoMacStatus = ""
                        discovery.scan()
                    } label: {
                        Label(discovery.isScanning
                              ? "Scanning… (\(discovery.methodHint))"
                              : "Scan Local Network",
                              systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(discovery.isScanning)

                    if discovery.devices.isEmpty {
                        Text("No devices yet. Tap Scan, or enter IP below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Discovered TVs", selection: $ip) {
                            ForEach(discovery.devices) { dev in
                                let label = (dev.friendlyName ?? dev.modelName ?? "TV")
                                Text("\(label) – \(dev.ip)").tag(dev.ip)
                            }
                        }
                        .onChange(of: ip) { newIP in
                            guard !newIP.isEmpty else { return }
                            if let pick = discovery.devices.first(where: { $0.ip == newIP }) {
                                if (pick.server ?? "").lowercased().contains("bonjour") { brand = "LG" }
                                if let n = pick.friendlyName, !n.isEmpty { name = n }
                            }
                            fetchMac(for: newIP)
                        }
                    }

                    // manual IP as backup
                    TextField("Or enter IP manually (e.g., 192.168.29.29)", text: $ip)
                        .keyboardType(.decimalPad)
                        .onSubmit { if !ip.isEmpty { fetchMac(for: ip) } }
                }

                // ── Details ─────────────────────────────────────────────────────
                Section("Details") {
                    TextField("Brand", text: $brand)
                    TextField("Nickname", text: $name)
                    HStack {
                        TextField("MAC Address (AA:BB:CC:DD:EE:FF)", text: $mac)
                            .textInputAutocapitalization(.characters)
                        if !autoMacStatus.isEmpty {
                            Spacer()
                            Text(autoMacStatus).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if !mac.isEmpty {
                        Text("Detected MAC: \(mac)").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                // ── Pair / Save ─────────────────────────────────────────────────
                Section {
                    Button {
                        pairAndSave()
                    } label: {
                        if isPairing { ProgressView() }
                        else {
                            Label("Pair & Save", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty ||
                              mac.trimmingCharacters(in: .whitespaces).isEmpty ||
                              isPairing)

                    if !pairStatus.isEmpty {
                        Text(pairStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Pair New TV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Auto MAC fetch

    private func fetchMac(for ip: String) {
        autoMacStatus = "Fetching MAC…"
        let tv = WebOSTV()
        tv.connect(ip: ip) { ok, _ in
            if ok {
                tv.fetchMacAddress { found in
                    DispatchQueue.main.async {
                        if let found, !found.isEmpty {
                            self.mac = found.uppercased()
                            self.autoMacStatus = "✓"
                        } else {
                            self.autoMacStatus = "Not found"
                        }
                        tv.disconnect()
                    }
                }
            } else {
                DispatchQueue.main.async { self.autoMacStatus = "TV not reachable" }
            }
        }
    }

    // MARK: - Pair & Save

    private func pairAndSave() {
        isPairing = true
        pairStatus = "Connecting…"

        let targetIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetMAC = mac.trimmingCharacters(in: .whitespacesAndNewlines)

        let tv = WebOSTV()
        tv.connect(ip: targetIP) { ok, msg in
            DispatchQueue.main.async {
                self.isPairing = false
                if ok {
                    UserDefaults.standard.set(targetIP, forKey: "LGRemoteMVP.lastIP")
                    UserDefaults.standard.set(targetMAC, forKey: "LGRemoteMVP.lastMAC")

                    let saved = SavedTV(
                        brand: brand.trimmingCharacters(in: .whitespacesAndNewlines),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        ip: targetIP,
                        mac: targetMAC,
                        lastSeen: Date()
                    )
                    store.addOrUpdate(saved)
                    pairStatus = "Paired & Saved!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                } else {
                    pairStatus = "Failed: \(msg)"
                }
            }
        }
    }
}

