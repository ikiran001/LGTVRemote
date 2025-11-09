import SwiftUI
import Combine

/// Home screen
/// - Lists saved TVs
/// - Connect/Disconnect + Wake
/// - Pair new TV
/// - ✅ Open Remote button (navigates to RemoteView)
struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings          // from App root
    @StateObject private var tv = WebOSTV()                        // single TV session
    @StateObject private var store = SavedTVStore.shared

    @State private var showPair = false
    @State private var ip: String = WebOSTV.savedIP ?? ""
    @State private var mac: String = WebOSTV.savedMAC ?? ""
    @State private var status: String = "Idle"

    // Navigation to Remote
    @State private var goRemote = false

    var body: some View {
        NavigationStack {
            List {
                // ── Status ─────────────────────────────────────────────────────
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(tv.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(tv.isConnected ? "Connected" : "Not connected")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // ── Saved TVs ──────────────────────────────────────────────────
                Section("Saved TVs") {
                    if store.items.isEmpty {
                        Text("No saved TVs. Tap “Pair New TV”.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name.isEmpty ? item.brand : item.name)
                                        .font(.headline)
                                    Text("\(item.ip) • \(item.mac)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    ip = item.ip
                                    mac = item.mac
                                } label: {
                                    Image(systemName: "arrow.down.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete { idx in store.delete(at: idx) }
                    }
                }

                // ── Target / Controls ──────────────────────────────────────────
                Section("Current Target") {
                    TextField("TV IP (e.g., 192.168.29.29)", text: $ip)
                        .keyboardType(.decimalPad)

                    TextField("TV MAC (AA:BB:CC:DD:EE:FF)", text: $mac)
                        .textInputAutocapitalization(.characters)

                    HStack {
                        Button {
                            connect()
                        } label: {
                            Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button {
                            tv.disconnect()
                            status = "Disconnected"
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!tv.isConnected)
                    }

                    Button {
                        let opts = WakeOnLAN.Options(bursts: 6, burstGapMs: 120, ports: [9,7], alsoUnicast: true)
                        WakeOnLAN.wake(macAddress: mac, ipHint: ip, options: opts) { ok in
                            status = ok ? "Wake sent" : "Wake failed"
                        }
                    } label: {
                        Label("Wake TV", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                    .disabled(mac.trimmingCharacters(in: .whitespaces).isEmpty)

                    if !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Remote shortcut ────────────────────────────────────────────
                Section {
                    Button {
                        // If not connected we still let user open the remote UI;
                        // they can use Wake/Connect from there too.
                        if !tv.isConnected, !ip.isEmpty {
                            connect { _ in goRemote = true }
                        } else {
                            goRemote = true
                        }
                    } label: {
                        Label("Open Remote", systemImage: "gamecontroller.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accentColor)
                    .disabled(ip.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // ── Pair ───────────────────────────────────────────────────────
                Section {
                    Button {
                        showPair = true
                    } label: {
                        Label("Pair New TV", systemImage: "link.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                // ── Appearance ────────────────────────────────────────────────
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)

                    Picker("Accent", selection: $settings.accent) {
                        Text("Blue").tag("blue")
                        Text("Teal").tag("teal")
                        Text("Indigo").tag("indigo")
                        Text("Pink").tag("pink")
                        Text("Orange").tag("orange")
                        Text("Purple").tag("purple")
                        Text("Red").tag("red")
                    }
                }
            }
            .navigationTitle("Home")
            .sheet(isPresented: $showPair) {
                PairTVView(store: store)
                    .environmentObject(settings)
            }
            // Hidden link that actually pushes RemoteView when goRemote toggles
            .background(
                NavigationLink("", isActive: $goRemote) {
                    RemoteView(tv: tv)
                        .environmentObject(settings)
                }.opacity(0)
            )
        }
        .preferredColorScheme(settings.colorScheme)
        .tint(settings.accentColor)
        .onAppear {
            ip = WebOSTV.savedIP ?? ip
            mac = WebOSTV.savedMAC ?? mac
        }
    }

    // MARK: - Actions
    private func connect(after: ((Bool) -> Void)? = nil) {
        status = "Connecting…"
        tv.connect(ip: ip) { ok, msg in
            if ok {
                status = "Connected"
                UserDefaults.standard.set(ip, forKey: "LGRemoteMVP.lastIP")
                UserDefaults.standard.set(mac, forKey: "LGRemoteMVP.lastMAC")
            } else {
                status = "Failed: \(msg)"
            }
            after?(ok)
        }
    }
}

