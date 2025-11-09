import SwiftUI
import Combine

struct ContentView: View {
    // Settings + TV session
    @StateObject private var settings = AppSettings()
    @StateObject private var tv = WebOSTV()

    // Saved TVs store (used by Pair sheet)
    @StateObject private var store = SavedTVStore.shared

    // UI state
    @State private var showPairSheet = false
    @State private var ip: String = WebOSTV.savedIP ?? ""
    @State private var mac: String = WebOSTV.savedMAC ?? ""
    @State private var status: String = "Idle"

    // Navigation to Remote
    @State private var goRemote = false

    var body: some View {
        NavigationStack {
            List {
                // Connection status
                Section {
                    HStack {
                        Circle()
                            .fill(tv.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(tv.isConnected ? "TV Connected" : "Not Connected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // Saved TVs
                Section("Saved TVs") {
                    if store.items.isEmpty {
                        Text("No saved TVs. Tap “Pair New TV”.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name.isEmpty ? item.brand : item.name)
                                        .font(.headline)
                                    Text("\(item.ip)  •  \(item.mac)")
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

                // Target & controls
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
                        // Wake uses MAC; IP (if provided) is a hint for directed broadcast.
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

                // ✅ Open Remote shortcut
                Section {
                    Button {
                        if !tv.isConnected, !ip.trimmingCharacters(in: .whitespaces).isEmpty {
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

                // Pairing
                Section {
                    Button {
                        showPairSheet = true
                    } label: {
                        Label("Pair New TV", systemImage: "link.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                // Appearance
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

                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                }
            }
            .navigationTitle("LG Remote MVP")
            .sheet(isPresented: $showPairSheet) {
                PairTVView(store: store)
                    .environmentObject(settings)
            }
            // Hidden NavigationLink that triggers when goRemote is set
            .background(
                NavigationLink("", isActive: $goRemote) {
                    RemoteView(tv: tv)
                        .environmentObject(settings)
                }
                .opacity(0)
            )
        }
        .preferredColorScheme(settings.colorScheme)
        .tint(settings.accentColor)
        .onAppear {
            // prefill fields from last session
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

    private func connect() { connect(after: nil) }
}

