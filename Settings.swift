import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    // Available options mapped to the strings AppSettings stores
    private let themeOptions: [(label: String, value: String)] = [
        ("System", "system"), ("Light", "light"), ("Dark", "dark")
    ]
    private let accentOptions: [(label: String, value: String)] = [
        ("Blue", "blue"), ("Teal", "teal"), ("Indigo", "indigo"),
        ("Pink", "pink"), ("Orange", "orange"), ("Purple", "purple"), ("Red", "red")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(themeOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Accent", selection: $settings.accent) {
                        ForEach(accentOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }

                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                }

                Section(footer: Text("Accent and theme apply across Home, Pair, and Remote.")
                    .font(.caption).foregroundStyle(.secondary)) {
                    ColorPreview(title: "Preview", color: settings.accentColor)
                }
            }
            .navigationTitle("Settings")
            .preferredColorScheme(settings.colorScheme)
            .tint(settings.accentColor)
        }
    }
}

private struct ColorPreview: View {
    let title: String
    let color: Color
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            RoundedRectangle(cornerRadius: 10)
                .fill(color)
                .frame(width: 80, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
        }
    }
}

