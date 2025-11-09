import SwiftUI

@main
struct LGRemoteMVPApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)                 // if any child wants it via @EnvironmentObject
                .preferredColorScheme(settings.colorScheme)   // uses computed property, not "theme.scheme"
                .tint(settings.accentColor)                  // uses a Color (ShapeStyle), fixes the tint error
        }
    }
}

