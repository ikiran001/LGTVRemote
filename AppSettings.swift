import Foundation
import Combine
import SwiftUI   // for Color / ColorScheme

/// Central user preferences (theme, accent, haptics)
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    @Published var theme: String {               // "system" | "light" | "dark"
        didSet { UserDefaults.standard.set(theme, forKey: "LGRemoteMVP.theme") }
    }

    @Published var accent: String {              // "blue" | "teal" | "indigo" | "pink" | etc.
        didSet { UserDefaults.standard.set(accent, forKey: "LGRemoteMVP.accent") }
    }

    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "LGRemoteMVP.haptics") }
    }

    // Public init so @StateObject AppSettings() works in LGRemoteMVPApp
    init() {
        self.theme = UserDefaults.standard.string(forKey: "LGRemoteMVP.theme") ?? "system"
        self.accent = UserDefaults.standard.string(forKey: "LGRemoteMVP.accent") ?? "blue"
        self.hapticsEnabled = UserDefaults.standard.object(forKey: "LGRemoteMVP.haptics") as? Bool ?? true
    }

    // Convenience values the App uses
    var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil    // system
        }
    }

    var accentColor: Color {
        switch accent.lowercased() {
        case "teal":   return .teal
        case "indigo": return .indigo
        case "pink":   return .pink
        case "orange": return .orange
        case "purple": return .purple
        case "red":    return .red
        default:       return .blue
        }
    }

    // Stored last targets for convenience
    var lastIP: String?  { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastIP") }
    var lastMAC: String? { UserDefaults.standard.string(forKey: "LGRemoteMVP.lastMAC") }
}

