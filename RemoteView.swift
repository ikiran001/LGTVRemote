import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct RemoteView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject var tv: WebOSTV

    // UI state
    @State private var isMuted: Bool = false
    @State private var listening: Bool = false

    // wake/auto-connect retry timer
    @State private var wakeRetries: Int = 0
    @State private var wakeTimer: Timer?

    // connection indicator state (shown on Power button)
    fileprivate enum ConnState { case disconnected, connecting, connected }
    @State private var connState: ConnState = .disconnected

    // Background driven by current accent color
    private var bgGradient: LinearGradient {
        let a = settings.accentColor
        return LinearGradient(colors: [a.opacity(0.30), .black, a.opacity(0.25)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            bgGradient.ignoresSafeArea()
                .overlay(RadialGradient(colors: [.white.opacity(0.05), .clear],
                                        center: .center, startRadius: 10, endRadius: 500)
                    .blur(radius: 40))

            ScrollView {
                VStack(spacing: 20) {
                    // Top bar
                    HStack(spacing: 16) {
                        IconGlassButtonBig(system: "chevron.backward") { haptic(.soft); tv.sendButton(key: "BACK") }
                        IconGlassButtonBig(system: "house")           { haptic(.soft); tv.sendButton(key: "HOME") }
                        Spacer()
                        PowerGlassButton(state: connState) { haptic(.rigid); togglePower() }
                    }
                    .padding(.horizontal)

                    // D-Pad
                    DPad(neon: settings.accentColor) { sendDPad($0) } onHold: { sendDPad($0) }
                        .padding(.top, 4)

                    // Mute + Voice
                    HStack(spacing: 16) {
                        ToggleGlass(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    title: isMuted ? "Muted" : "Mute",
                                    isOn: $isMuted,
                                    active: settings.accentColor) { on in
                            tv.sendSimple(uri: "ssap://audio/setMute", payload: ["mute": on])
                        }

                        GlassButton(icon: "mic.circle.fill",
                                    title: listening ? "Listening" : "Voice",
                                    highlight: settings.accentColor.opacity(0.9)) {
                            if VoiceControl.shared.isListening {
                                VoiceControl.shared.stop(); listening = false
                            } else {
                                VoiceControl.shared.onCommand = { handleVoiceCommand($0) }
                                VoiceControl.shared.requestAuthorization { ok in
                                    if ok { VoiceControl.shared.start(); listening = true }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Volume
                    HStack(spacing: 16) {
                        RepeatGlassButton(icon: "minus.circle.fill", title: "Vol −",
                                          highlight: settings.accentColor.opacity(0.9),
                                          tapAction: { tv.sendSimple(uri: "ssap://audio/volumeDown") },
                                          repeatAction: { tv.sendSimple(uri: "ssap://audio/volumeDown") })

                        RepeatGlassButton(icon: "plus.circle.fill", title: "Vol +",
                                          highlight: settings.accentColor.opacity(0.9),
                                          tapAction: { tv.sendSimple(uri: "ssap://audio/volumeUp") },
                                          repeatAction: { tv.sendSimple(uri: "ssap://audio/volumeUp") })
                    }
                    .padding(.horizontal)

                    // App shortcuts
                    AppShortcuts(tv: tv, accent: settings.accentColor)

                    // Now playing (optional)
                    NowPlayingPanel(tv: tv)

                    // Status
                    VStack(spacing: 6) {
                        Text(tv.isConnected ? "Connected to \(tv.ip)" : "Not connected")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(tv.isConnected ? .green : .secondary)
                        if !tv.lastMessage.isEmpty {
                            Text(tv.lastMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 18)
            }
        }
        .preferredColorScheme(settings.colorScheme)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { appearanceMenu } }
        .onAppear {
            connState = tv.isConnected ? .connected : .disconnected
            tv.onConnect = { connState = .connected; notifySuccess() }
            tv.onDisconnect = { connState = .disconnected; notifyWarning() }
            tv.startNowPlayingUpdates()
        }
        .onDisappear {
            tv.stopNowPlayingUpdates()
            invalidateWakeTimer()
            if VoiceControl.shared.isListening { VoiceControl.shared.stop() }
            listening = false
        }
        .onChange(of: isMuted) { on in
            tv.sendSimple(uri: "ssap://audio/setMute", payload: ["mute": on])
        }
        .onChange(of: tv.isConnected) { ok in
            connState = ok ? .connected : .disconnected
        }
    }

    // MARK: Voice

    private func handleVoiceCommand(_ cmd: VoiceControl.Command) {
        switch cmd {
        case .volumeUp:   tv.sendSimple(uri: "ssap://audio/volumeUp")
        case .volumeDown: tv.sendSimple(uri: "ssap://audio/volumeDown")
        case .muteOn:     isMuted = true;  tv.sendSimple(uri: "ssap://audio/setMute", payload: ["mute": true])
        case .muteOff:    isMuted = false; tv.sendSimple(uri: "ssap://audio/setMute", payload: ["mute": false])
        case .muteToggle: isMuted.toggle(); tv.sendSimple(uri: "ssap://audio/setMute", payload: ["mute": isMuted])

        case .powerOff: if tv.isConnected { tv.sendSimple(uri: "ssap://system/turnOff") }
        case .powerOn:  togglePower()

        case .channelUp:   tv.sendButton(key: "CHANNELUP")
        case .channelDown: tv.sendButton(key: "CHANNELDOWN")

        case .navUp:    tv.sendButton(key: "UP")
        case .navDown:  tv.sendButton(key: "DOWN")
        case .navLeft:  tv.sendButton(key: "LEFT")
        case .navRight: tv.sendButton(key: "RIGHT")
        case .ok:       tv.sendButton(key: "OK")
        case .back:     tv.sendButton(key: "BACK")
        case .home:     tv.sendButton(key: "HOME")

        case .open(let app):
            switch app {
            case .youtube:   tv.launchStreamingApp(.youtube)
            case .netflix:   tv.launchStreamingApp(.netflix)
            case .prime:     tv.launchStreamingApp(.prime)
            case .hotstar:   tv.launchStreamingApp(.hotstar)
            case .jiocinema: tv.launchStreamingApp(.jiocinema)
            case .sonyliv:   tv.launchStreamingApp(.sonyliv)
            }
        case .unknown:
            haptic(.soft)
        }
    }

    // MARK: Appearance menu

    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $settings.theme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Picker("Accent", selection: $settings.accent) {
                Text("Blue").tag("blue")
                Text("Teal").tag("teal")
                Text("Indigo").tag("indigo")
                Text("Pink").tag("pink")
                Text("Orange").tag("orange")
                Text("Purple").tag("purple")
                Text("Red").tag("red")
            }
        } label: {
            Image(systemName: "paintbrush.pointed")
                .font(.headline)
                .foregroundStyle(.white)
        }
    }

    // MARK: D-pad + Power

    private func sendDPad(_ dir: DPadDirection) {
        switch dir {
        case .up:    tv.sendButton(key: "UP")
        case .down:  tv.sendButton(key: "DOWN")
        case .left:  tv.sendButton(key: "LEFT")
        case .right: tv.sendButton(key: "RIGHT")
        case .ok:    tv.sendButton(key: "OK")
        }
    }

    private func togglePower() {
        if tv.isConnected {
            tv.sendSimple(uri: "ssap://system/turnOff")
            return
        }
        let ipHint = UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP")
        let mac = UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") ?? ""
        guard !mac.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        connState = .connecting

        let opts = WakeOnLAN.Options(bursts: 6, burstGapMs: 120, ports: [9,7], alsoUnicast: true)
        WakeOnLAN.wake(macAddress: mac, ipHint: ipHint, options: opts, completion: nil)

        wakeRetries = 0
        invalidateWakeTimer()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard let ip = ipHint, !ip.isEmpty else { self.invalidateWakeTimer(); return }
            if self.wakeRetries > 15 {
                self.invalidateWakeTimer()
                self.connState = .disconnected
                return
            }
            self.wakeRetries += 1
            Ping.isReachable(ip: ip) { ok in
                if ok {
                    DispatchQueue.main.async {
                        self.invalidateWakeTimer()
                        self.tv.connect(ip: ip) { _, _ in }
                    }
                }
            }
        }
    }

    private func invalidateWakeTimer() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        wakeRetries = 0
    }

    // MARK: Haptics

    private func notifySuccess() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    private func notifyWarning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

//
// MARK: - Helper views
//

private struct IconGlassButtonBig: View {
    let system: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.28), lineWidth: 1))
        }
    }
}

private struct PowerGlassButton: View {
    let state: RemoteView.ConnState
    var action: () -> Void
    @State private var pulse = false
    private var tint: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [tint.opacity(0.98), tint.opacity(0.78)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.20), lineWidth: 1))
                .shadow(color: tint.opacity(0.65), radius: 14)
                .scaleEffect(state == .connecting ? (pulse ? 1.06 : 0.96) : 1.0)
                .animation(state == .connecting ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
        }
        .onAppear { if state == .connecting { pulse = true } }
        .onChange(of: state) { s in pulse = (s == .connecting) }
    }
}

private struct GlassButton: View {
    let icon: String
    let title: String
    var highlight: Color? = nil
    var action: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 26, weight: .semibold)).shadow(radius: 8)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: 160, minHeight: 68)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke((highlight ?? .white).opacity(0.28), lineWidth: 1))
        .onTapGesture { action() }
    }
}

private struct ToggleGlass: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    var active: Color
    var onToggle: (Bool) -> Void
    var body: some View {
        Button {
            isOn.toggle()
            onToggle(isOn)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 160, minHeight: 68)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke((isOn ? active : .white).opacity(0.28), lineWidth: 1))
        }
    }
}

private struct RepeatGlassButton: View {
    let icon: String
    let title: String
    var highlight: Color? = nil
    var tapAction: () -> Void
    var repeatAction: (() -> Void)? = nil
    var initialDelay: TimeInterval = 0.30
    var repeatInterval: TimeInterval = 0.25
    @State private var holdTimer: Timer? = nil
    @State private var pendingStart: DispatchWorkItem? = nil
    @State private var isPressed = false
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 28, weight: .semibold)).shadow(radius: 8)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: 160, minHeight: 68)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke((highlight ?? .white).opacity(0.28), lineWidth: 1))
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .onTapGesture { tapAction(); haptic(.light) }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            if pressing {
                isPressed = true
                let task = DispatchWorkItem { if isPressed { startTimer() } }
                pendingStart = task
                DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay, execute: task)
            } else {
                isPressed = false
                pendingStart?.cancel(); pendingStart = nil
                stopTimer()
            }
        }, perform: {})
    }
    private func startTimer() {
        guard holdTimer == nil, let repeatAction else { return }
        repeatAction(); haptic(.soft)
        holdTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { _ in
            repeatAction(); haptic(.soft)
        }
    }
    private func stopTimer() { holdTimer?.invalidate(); holdTimer = nil }
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

private enum DPadDirection { case up, down, left, right, ok }

private struct DPad: View {
    let neon: Color
    var tapAction: (DPadDirection) -> Void
    var onHold: (DPadDirection) -> Void
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
                .frame(width: 200, height: 200)
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            Group {
                RepeatDPadButton(icon: "chevron.up",   neon: neon, size: 64, tap: { tapAction(.up) },   hold: { onHold(.up)   }).offset(y: -82)
                RepeatDPadButton(icon: "chevron.down", neon: neon, size: 64, tap: { tapAction(.down) }, hold: { onHold(.down) }).offset(y: 82)
                RepeatDPadButton(icon: "chevron.left", neon: neon, size: 64, tap: { tapAction(.left) }, hold: { onHold(.left) }).offset(x: -82)
                RepeatDPadButton(icon: "chevron.right", neon: neon, size: 64, tap: { tapAction(.right) }, hold: { onHold(.right)}).offset(x: 82)
            }
            GlassOK(neon: neon, size: 88) { tapAction(.ok) }
        }
        .padding(.top, 2)
    }
}

private struct RepeatDPadButton: View {
    let icon: String
    let neon: Color
    var size: CGFloat = 54
    var tap: () -> Void
    var hold: () -> Void
    var initialDelay: TimeInterval = 0.35
    var repeatInterval: TimeInterval = 0.22
    @State private var holdTimer: Timer? = nil
    @State private var isPressed = false
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
            .overlay(Image(systemName: icon)
                .font(.system(size: min(22, size * 0.38), weight: .semibold))
                .foregroundStyle(.white))
            .shadow(color: neon.opacity(0.45), radius: 8)
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isPressed)
            .onTapGesture { tap(); haptic(.light) }
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
                if pressing {
                    isPressed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
                        guard isPressed else { return }
                        startTimer()
                    }
                } else {
                    isPressed = false
                    stopTimer()
                }
            }, perform: {})
    }
    private func startTimer() {
        stopTimer()
        holdTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { _ in
            hold(); haptic(.soft)
        }
    }
    private func stopTimer() { holdTimer?.invalidate(); holdTimer = nil }
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

private struct GlassOK: View {
    let neon: Color
    var size: CGFloat = 74
    var tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Circle()
                .fill(LinearGradient(colors: [neon.opacity(0.35), neon.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(neon.opacity(0.5), lineWidth: 1.2))
                .overlay(Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: min(28, size * 0.32), weight: .semibold)))
                .shadow(color: neon.opacity(0.45), radius: 10)
        }
    }
}

// Simple “Apps” area
private struct AppShortcuts: View {
    let tv: WebOSTV
    let accent: Color
    private struct Shortcut: Identifiable {
        let id = UUID(); let title: String; let systemIcon: String; let action: () -> Void
    }
    var body: some View {
        let shortcuts: [Shortcut] = [
            .init(title: "YouTube",  systemIcon: "play.rectangle.fill") { tv.launchStreamingApp(.youtube) },
            .init(title: "Netflix",  systemIcon: "n.square.fill")       { tv.launchStreamingApp(.netflix) },
            .init(title: "Prime",    systemIcon: "a.square.fill")       { tv.launchStreamingApp(.prime) },
            .init(title: "Hotstar",  systemIcon: "star.circle.fill")    { tv.launchStreamingApp(.hotstar) },
            .init(title: "JioCinema",systemIcon: "film.circle.fill")    { tv.launchStreamingApp(.jiocinema) },
            .init(title: "Sony LIV", systemIcon: "s.square.fill")       { tv.launchStreamingApp(.sonyliv) }
        ]
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps").font(.headline).foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                ForEach(shortcuts) { item in
                    Button { item.action() } label: {
                        VStack(spacing: 8) {
                            Image(systemName: item.systemIcon)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)   // ← width constraint
                        .frame(height: 74)            // ← height on a separate call (fixes your error)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.25), lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .padding(.top, 6)
    }
}

private struct NowPlayingPanel: View {
    @ObservedObject var tv: WebOSTV
    var body: some View {
        if let np = tv.nowPlaying {
            VStack(alignment: .leading, spacing: 6) {
                Text("Now Playing").font(.headline).foregroundStyle(.white.opacity(0.9))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.appTitle.isEmpty ? np.appId : np.appTitle).font(.subheadline.weight(.semibold))
                        if !np.playState.isEmpty {
                            Text(np.playState.uppercased()).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Refresh") { tv.startNowPlayingUpdates() }.buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }
}

