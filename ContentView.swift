import SwiftUI

struct ContentView: View {
    private enum ConnectStatus: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
    }

    enum Field: Hashable { case ip, mac }

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var tv = WebOSTV()
    @StateObject private var store = SavedTVStore.shared

    @State private var connectStatus: ConnectStatus = .idle
    @State private var manualIP: String = WebOSTV.savedIP ?? ""
    @State private var manualMAC: String = WebOSTV.savedMAC ?? ""
    @State private var footnote: String = "Ready when you are."
    @State private var showPairSheet = false
    @State private var activeSavedTVId: UUID?
    @State private var remoteActive = false
    @State private var remoteContextName: String = ""
    @State private var pendingRemoteIP: String?
    @State private var pendingRemoteName: String = ""
    @State private var manualDisconnect = false

    @FocusState private var focusedField: Field?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {
                        statusCard
                        heroPairCard
                        savedTVSection
                        manualControlCard
                        appearanceCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 32)
                }
            }
            .navigationTitle("LG Remote Neo")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showPairSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Pair TV")
                }
            }
            .sheet(isPresented: $showPairSheet) {
                PairTVView(store: store)
                    .environmentObject(settings)
            }
            .background(
                NavigationLink("", isActive: $remoteActive) {
                    RemoteView(tv: tv, displayName: remoteContextName)
                        .environmentObject(settings)
                }
                .opacity(0)
            )
        }
        .preferredColorScheme(settings.colorScheme)
        .tint(settings.accentColor)
        .onAppear {
            tv.onConnect = {
                connectStatus = .connected
                footnote = "Connected to \(connectionLabel(saved: activeSavedTV, ip: tv.ip))"
                manualDisconnect = false
            }
            tv.onDisconnect = {
                if manualDisconnect {
                    footnote = "Disconnected"
                } else {
                    footnote = "Connection lost"
                }
                manualDisconnect = false
                connectStatus = .idle
                pendingRemoteIP = nil
                pendingRemoteName = ""
            }
            manualIP = WebOSTV.savedIP ?? manualIP
            manualMAC = WebOSTV.savedMAC ?? manualMAC
        }
    }

    // MARK: - Sections

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    Circle()
                        .fill(
                            RadialGradient(colors: [statusColor.opacity(0.85), statusColor.opacity(0.3)],
                                           center: .center, startRadius: 4, endRadius: 32)
                        )
                        .frame(width: 22, height: 22)
                        .shadow(color: statusColor.opacity(0.55), radius: 14)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.title3.weight(.semibold))
                        Text(statusSubtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if case .connecting = connectStatus {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(settings.accentColor)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.12))

                HStack(spacing: 18) {
                    Label(manualIPDisplay, systemImage: "wifi.router")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(tv.isConnected ? "Secure channel active" : "Awaiting pairing", systemImage: tv.isConnected ? "lock.shield" : "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var heroPairCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Command every screen with a single tap.")
                    .font(.title2.weight(.semibold))
                Text("Discover LG webOS TVs on your Wi-Fi, auto-fetch IP & MAC, and create dedicated remotes for each room.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    showPairSheet = true
                } label: {
                    Label("Discover & Pair Now", systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(colors: [settings.accentColor.opacity(0.85),
                                                            settings.accentColor.opacity(0.45)],
                                                   startPoint: .leading, endPoint: .trailing)
                                )
                                .shadow(color: settings.accentColor.opacity(0.55), radius: 12, x: 0, y: 6)
                        )
                        .foregroundStyle(Color.black.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
        }
    }

    private var savedTVSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Saved TVs")
                    .font(.headline)

                if store.items.isEmpty {
                    Text("Once paired, each TV appears here with instant connect and individual remote access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(store.items) { item in
                                savedTVCard(for: item)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var manualControlCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Manual Control Center")
                    .font(.headline)
                Text("Select a saved TV or enter an address manually to link instantly. You’ll always have a dedicated remote ready to go.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: 14) {
                    futuristicField(icon: "network", placeholder: "IP Address (e.g. 192.168.1.25)",
                                    text: $manualIP, field: .ip, capitalization: .never)
                        .keyboardType(.decimalPad)

                    futuristicField(icon: "barcode", placeholder: "MAC Address (AA:BB:CC:DD:EE:FF)",
                                    text: $manualMAC, field: .mac, capitalization: .characters)
                }

                HStack(spacing: 12) {
                    Button {
                        connectCurrent()
                    } label: {
                        Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(settings.accentColor)
                    .disabled(manualIP.trimmed.isEmpty || isConnecting)

                    Button {
                        openRemote(for: nil)
                    } label: {
                        Label("Remote", systemImage: "gamecontroller.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(settings.accentColor)
                    .disabled(manualIP.trimmed.isEmpty)
                }

                HStack(spacing: 12) {
                    Button {
                        wakeCurrent()
                    } label: {
                        Label("Wake TV", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(manualMAC.trimmed.isEmpty)

                    Button(role: .cancel) {
                        disconnectCurrent()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(!tv.isConnected)
                }

                if !footnote.isEmpty {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var appearanceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Personalize the cockpit")
                    .font(.headline)

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

                Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
            }
        }
    }

    // MARK: - Components

    private func savedTVCard(for item: SavedTV) -> some View {
        let isActive = tv.isConnected && tv.ip == item.ip
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(.headline)
                    Text(relativeString(for: item.lastSeen))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    BadgeView(text: "Active", color: settings.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(item.ip, systemImage: "wifi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(item.mac, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    connect(saved: item)
                } label: {
                    Label("Connect", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(settings.accentColor)

                Button {
                    openRemote(for: item)
                } label: {
                    Label("Remote", systemImage: "gamecontroller")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(18)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(isActive ? settings.accentColor.opacity(0.9) : Color.white.opacity(0.18),
                                lineWidth: isActive ? 2 : 1)
                )
                .shadow(color: settings.accentColor.opacity(isActive ? 0.4 : 0.18),
                        radius: isActive ? 20 : 10, x: 0, y: isActive ? 14 : 8)
        )
    }

    private func futuristicField(icon: String,
                                 placeholder: String,
                                 text: Binding<String>,
                                 field: Field,
                                 capitalization: TextInputAutocapitalization) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(settings.accentColor)
                .font(.system(size: 18, weight: .semibold))
            TextField(placeholder, text: text)
                .focused($focusedField, equals: field)
                .textInputAutocapitalization(capitalization)
                .disableAutocorrection(true)
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focusedField == field ? settings.accentColor.opacity(0.85) : Color.white.opacity(0.14),
                        lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.09, blue: 0.18),
                Color(red: 0.06, green: 0.02, blue: 0.27),
                settings.accentColor.opacity(0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var statusColor: Color {
        switch connectStatus {
        case .connected:
            return Color.green
        case .connecting:
            return settings.accentColor
        case .failed:
            return Color.red
        case .idle:
            return tv.isConnected ? Color.green : Color.gray.opacity(0.6)
        }
    }

    private var statusTitle: String {
        switch connectStatus {
        case .connected:
            return "Linked"
        case .connecting:
            return "Connecting…"
        case .failed:
            return "Needs Attention"
        case .idle:
            return tv.isConnected ? "Linked" : "Standing By"
        }
    }

    private var statusSubtitle: String {
        switch connectStatus {
        case .connected:
            return "Connected to \(connectionLabel(saved: activeSavedTV, ip: tv.ip))"
        case .connecting(let ip):
            return "Negotiating secure channel with \(ip)"
        case .failed(let message):
            return message
        case .idle:
            if tv.isConnected {
                return "Connected to \(connectionLabel(saved: activeSavedTV, ip: tv.ip))"
            }
            return "Tap a saved TV or enter an address below to begin."
        }
    }

    private var statusIcon: String {
        switch connectStatus {
        case .connected:
            return "bolt.horizontal.circle.fill"
        case .connecting:
            return "waveform"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return tv.isConnected ? "bolt.horizontal.circle" : "antenna.radiowaves.left.and.right"
        }
    }

    private var manualIPDisplay: String {
        let trimmed = manualIP.trimmed
        return trimmed.isEmpty ? "No target selected" : trimmed
    }

    private var isConnecting: Bool {
        if case .connecting = connectStatus { return true }
        return false
    }

    private var activeSavedTV: SavedTV? {
        guard let id = activeSavedTVId else { return nil }
        return store.items.first(where: { $0.id == id })
    }

    private func connectionLabel(saved: SavedTV?, ip: String) -> String {
        if let saved { return saved.displayName }
        let effectiveIP = ip.trimmed.isEmpty ? manualIP.trimmed : ip.trimmed
        return effectiveIP.isEmpty ? "your TV" : "TV @ \(effectiveIP)"
    }

    private func relativeString(for date: Date) -> String {
        ContentView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    private func connectCurrent() {
        connect(ip: manualIP, mac: manualMAC, saved: nil, autoLaunchName: nil)
    }

    private func connect(saved: SavedTV) {
        connect(ip: saved.ip, mac: saved.mac, saved: saved, autoLaunchName: nil)
    }

    private func connect(ip: String, mac: String, saved: SavedTV?, autoLaunchName: String?) {
        let trimmedIP = ip.trimmed
        let trimmedMAC = mac.trimmed

        guard !trimmedIP.isEmpty else {
            connectStatus = .failed("Missing IP address")
            footnote = "Enter the TV's IP address to connect."
            return
        }

        activeSavedTVId = saved?.id

        if let autoLaunchName {
            pendingRemoteIP = trimmedIP
            pendingRemoteName = autoLaunchName
        } else {
            pendingRemoteIP = nil
            pendingRemoteName = ""
        }

        manualIP = trimmedIP
        if !trimmedMAC.isEmpty {
            manualMAC = trimmedMAC
        }

        connectStatus = .connecting(trimmedIP)
        footnote = "Connecting to \(trimmedIP)…"

        tv.connect(ip: trimmedIP) { ok, message in
            DispatchQueue.main.async {
                if ok {
                    self.connectStatus = .connected
                    self.footnote = "Connected to \(connectionLabel(saved: saved, ip: trimmedIP))"
                    UserDefaults.standard.set(trimmedIP, forKey: "LGRemoteMVP.lastIP")
                    if !trimmedMAC.isEmpty {
                        UserDefaults.standard.set(trimmedMAC, forKey: "LGRemoteMVP.lastMAC")
                    }
                    if let saved {
                        store.markSeen(id: saved.id)
                    }
                    if let remoteIP = self.pendingRemoteIP, remoteIP == trimmedIP {
                        self.remoteContextName = self.pendingRemoteName.isEmpty
                            ? connectionLabel(saved: saved, ip: trimmedIP)
                            : self.pendingRemoteName
                        self.pendingRemoteIP = nil
                        self.pendingRemoteName = ""
                        self.remoteActive = true
                    }
                } else {
                    let failure = message.isEmpty ? "Failed to connect" : message
                    self.connectStatus = .failed(failure)
                    self.footnote = failure.hasPrefix("Failed") ? failure : "Failed: \(failure)"
                    if let remoteIP = self.pendingRemoteIP, remoteIP == trimmedIP {
                        self.pendingRemoteIP = nil
                        self.pendingRemoteName = ""
                    }
                }
            }
        }
    }

    private func openRemote(for saved: SavedTV?) {
        let targetIP = saved?.ip ?? manualIP
        let targetMAC = saved?.mac ?? manualMAC
        let trimmedIP = targetIP.trimmed

        guard !trimmedIP.isEmpty else {
            footnote = "Enter a TV IP before opening the remote."
            return
        }

        let label = connectionLabel(saved: saved, ip: trimmedIP)

        if tv.isConnected && tv.ip == trimmedIP {
            remoteContextName = label
            remoteActive = true
        } else {
            connect(ip: trimmedIP, mac: targetMAC, saved: saved, autoLaunchName: label)
        }
    }

    private func wakeCurrent() {
        let trimmedMAC = manualMAC.trimmed
        guard !trimmedMAC.isEmpty else {
            footnote = "Add the TV's MAC address to send Wake-on-LAN."
            return
        }

        let options = WakeOnLAN.Options(bursts: 6, burstGapMs: 120, ports: [9, 7], alsoUnicast: true)
        WakeOnLAN.wake(macAddress: trimmedMAC, ipHint: manualIP.trimmed, options: options) { ok in
            DispatchQueue.main.async {
                footnote = ok ? "Wake signal sent to \(connectionLabel(saved: activeSavedTV, ip: manualIP))"
                              : "Wake failed – ensure the TV supports Wake-on-LAN."
            }
        }
    }

    private func disconnectCurrent() {
        manualDisconnect = true
        pendingRemoteIP = nil
        pendingRemoteName = ""
        tv.disconnect()
        connectStatus = .idle
        footnote = "Disconnected"
    }
}

// MARK: - Subviews

private struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
            )
    }
}

private struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.25))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color, lineWidth: 1)
            )
            .foregroundStyle(color)
    }
}

// MARK: - Utilities

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

