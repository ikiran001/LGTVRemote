import SwiftUI
import UIKit

struct RemoteView: View {
    @ObservedObject var tv: WebOSTV
    var displayName: String? = nil

    // Haptics
    private let impact = UIImpactFeedbackGenerator(style: .soft)

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
                        switch dir {
                        case .up: sendKey("UP")
                        case .down: sendKey("DOWN")
                        case .left: sendKey("LEFT")
                        case .right: sendKey("RIGHT")
                        case .ok: sendKey("ENTER")
                        }
                    }
                    .padding(.horizontal)

                    // Volume controls (long-press repeat)
                    VStack(spacing: 10) {
                        Text("Volume").font(.caption).foregroundStyle(.secondary)
                        RepeatPill(icon: "speaker.wave.3.fill", title: "Vol +") { sendKey("VOLUMEUP") }
                        RepeatPill(icon: "speaker.wave.1.fill", title: "Vol -") { sendKey("VOLUMEDOWN") }
                        PillButton(icon: "speaker.slash.fill", title: "Mute") { sendKey("MUTE") }
                    }
                    .frame(maxWidth: .infinity)
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
                              AppTile(title: "YouTube", abbreviation: "YT", tint: .red) { launch("youtube.leanback.v4") }
                              AppTile(title: "Netflix", abbreviation: "N", tint: .black) { launch("netflix") }
                              AppTile(title: "Prime", abbreviation: "PV", tint: Color(red: 0.08, green: 0.33, blue: 0.71)) { launch("amzn.tvarm") }
                              AppTile(title: "Hotstar", abbreviation: "HS", tint: Color(red: 0.02, green: 0.42, blue: 0.39)) { launch("com.startv.hotstar.lg") }
                              AppTile(title: "JioCinema", abbreviation: "JC", tint: Color(red: 0.57, green: 0.0, blue: 0.33)) { launch("com.jio.media.jioplay.tv") }
                              AppTile(title: "SonyLIV", abbreviation: "SL", tint: Color(red: 0.21, green: 0.16, blue: 0.55)) { launch("com.sonyliv.lg") }
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
              .onAppear { impact.prepare() }
        }
    }

    private func sendKey(_ name: String) {
        fireHaptic()
        guard tv.isConnected else { return }
        tv.sendButton(key: name)
    }

    private func launch(_ appId: String) {
        fireHaptic()
        guard tv.isConnected else { return }
        tv.launchStreamingApp(appId)
    }

    private var currentTargetLabel: String {
        let fallback = tv.ip.isEmpty ? "TV" : "TV @ \(tv.ip)"
        if let name = displayName, !name.isEmpty { return name }
        return fallback
    }

    private func fireHaptic() {
        impact.impactOccurred()
        impact.prepare()
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
                  RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08))
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
      let abbreviation: String
      let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
              VStack(spacing: 8) {
                  RoundedRectangle(cornerRadius: 18)
                      .fill(tint.opacity(0.35))
                      .overlay(
                          RoundedRectangle(cornerRadius: 18)
                              .stroke(tint.opacity(0.65), lineWidth: 1.5)
                      )
                      .overlay(
                          Text(abbreviation)
                              .font(.system(size: 24, weight: .bold))
                              .foregroundStyle(.white)
                      )
                      .frame(height: 64)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Grid D-pad (equal-width columns keep controls centered on all devices)
private struct DPadGrid: View {
    enum Dir { case up, down, left, right, ok }
    let tap: (Dir) -> Void

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let arrowHeight: CGFloat = 64
    private let okHeight: CGFloat = 92

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
            fillerCell
            Arrow("chevron.up") { tap(.up) }
            fillerCell

            Arrow("chevron.left") { tap(.left) }
            OK { tap(.ok) }
            Arrow("chevron.right") { tap(.right) }

            fillerCell
            Arrow("chevron.down") { tap(.down) }
            fillerCell
        }
    }

    private var fillerCell: some View {
        Color.clear
            .frame(height: arrowHeight)
    }

    private func Arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
                .frame(height: arrowHeight)
                .frame(maxWidth: .infinity)
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
                .fill(Color.white.opacity(0.1))
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                .frame(height: okHeight)
                .frame(maxWidth: .infinity)
                .overlay(
                    Text("OK")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
        .buttonStyle(.plain)
    }
}

