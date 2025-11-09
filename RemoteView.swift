import SwiftUI

struct RemoteView: View {
    @ObservedObject var tv: WebOSTV
    var displayName: String? = nil

    // Haptics
    private let impact = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // Status row
                    HStack(spacing: 10) {
                        Circle()
                            .fill(tv.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(tv.isConnected ? "Connected to \(currentTargetLabel)" : "Not connected")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal)

                    // Top controls: Back • Power • Home
                    HStack(spacing: 16) {
                        PillButton(icon: "chevron.backward", title: "Back") { sendKey("BACK") }
                        PowerButton(connected: tv.isConnected) { sendKey("POWER") }
                        PillButton(icon: "house.fill", title: "Home") { sendKey("HOME") }
                    }
                    .padding(.horizontal)

                    // D-Pad (aligned using Grid)
                    DPadGrid { dir in
                        impact.impactOccurred()
                        switch dir {
                        case .up: sendKey("UP")
                        case .down: sendKey("DOWN")
                        case .left: sendKey("LEFT")
                        case .right: sendKey("RIGHT")
                        case .ok: sendKey("ENTER")
                        }
                    }
                    .padding(.horizontal)

                    // Volume / Channel (long-press repeat)
                    HStack(spacing: 16) {
                        VStack(spacing: 10) {
                            Text("Volume").font(.caption).foregroundStyle(.secondary)
                            RepeatPill(icon: "speaker.wave.3.fill", title: "Vol +") { sendKey("VOLUMEUP") }
                            RepeatPill(icon: "speaker.wave.1.fill", title: "Vol -") { sendKey("VOLUMEDOWN") }
                            PillButton(icon: "speaker.slash.fill", title: "Mute") { sendKey("MUTE") }
                        }
                        VStack(spacing: 10) {
                            Text("Channel").font(.caption).foregroundStyle(.secondary)
                            RepeatPill(icon: "chevron.up", title: "CH +") { sendKey("CHANNELUP") }
                            RepeatPill(icon: "chevron.down", title: "CH -") { sendKey("CHANNELDOWN") }
                            PillButton(icon: "rectangle.and.hand.point.up.left.filled", title: "Guide") { sendKey("GUIDE") }
                        }
                    }
                    .padding(.horizontal)

                    // Media controls
                    HStack(spacing: 16) {
                        PillButton(icon: "backward.fill", title: "Rew") { sendKey("REWIND") }
                        PillButton(icon: "playpause.fill", title: "Play/Pause") { sendKey("PLAY") }
                        PillButton(icon: "forward.fill", title: "Fwd") { sendKey("FASTFORWARD") }
                    }
                    .padding(.horizontal)

                    // Apps
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Apps").font(.headline).padding(.horizontal)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            AppTile(title: "YouTube", system: "play.rectangle.fill") { launch("youtube.leanback.v4") }
                            AppTile(title: "Netflix", system: "n.circle.fill") { launch("netflix") }
                            AppTile(title: "Prime", system: "a.circle.fill") { launch("amzn.tvarm") }
                            AppTile(title: "Hotstar", system: "star.circle.fill") { launch("com.startv.hotstar.lg") }
                            AppTile(title: "JioCinema", system: "j.circle.fill") { launch("com.jio.media.jioplay.tv") }
                            AppTile(title: "SonyLIV", system: "s.circle.fill") { launch("com.sonyliv.lg") }
                        }
                        .padding(.horizontal)
                    }

                    if !tv.lastMessage.isEmpty {
                        Text(tv.lastMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(
                LinearGradient(colors: [Color.black, Color.blue.opacity(0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            )
            .navigationTitle(displayName ?? "Remote")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sendKey(_ name: String) {
        guard tv.isConnected else { return }
        tv.sendButton(key: name)
    }

    private func launch(_ appId: String) {
        guard tv.isConnected else { return }
        tv.launchStreamingApp(appId)
    }

    private var currentTargetLabel: String {
        let fallback = tv.ip.isEmpty ? "TV" : "TV @ \(tv.ip)"
        if let name = displayName, !name.isEmpty { return name }
        return fallback
    }
}

// MARK: - UI Components

private struct PillButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 86, height: 56)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RepeatPill: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        PillButton(icon: icon, title: title, action: action)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25).onEnded { _ in
                    action()
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { _ in action() }
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onEnded { _ in
                    timer?.invalidate()
                    timer = nil
                }
            )
    }
}

private struct PowerButton: View {
    let connected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle()
                    .fill((connected ? Color.green : Color.red).opacity(0.18))
                    .overlay(
                        Circle()
                            .stroke(connected ? Color.green : Color.red, lineWidth: 3)
                    )
                    .frame(width: 86, height: 86)
                    .shadow(color: (connected ? Color.green : Color.red).opacity(0.6), radius: 10)
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(connected ? Color.green : Color.red)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AppTile: View {
    let title: String
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .frame(height: 64)
                    .overlay(
                        Image(systemName: system)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Grid D-pad (no absolute positions → aligns on all screens)
private struct DPadGrid: View {
    enum Dir { case up, down, left, right, ok }
    let tap: (Dir) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Spacer()
                Arrow("chevron.up") { tap(.up) }
                Spacer()
            }
            HStack(spacing: 12) {
                Arrow("chevron.left") { tap(.left) }
                OK { tap(.ok) }
                Arrow("chevron.right") { tap(.right) }
            }
            HStack(spacing: 12) {
                Spacer()
                Arrow("chevron.down") { tap(.down) }
                Spacer()
            }
        }
    }

    private func Arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
                .frame(width: 92, height: 60)
                .overlay(
                    Image(systemName: name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .buttonStyle(.plain)
    }

    private func OK(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(.thinMaterial)
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                .frame(width: 90, height: 90)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
        .buttonStyle(.plain)
    }
}

