import SwiftUI
import StarPlayrRadioKit

@main
struct XMWatchApp: App {
    @State private var radioService = XMRadioService.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("xm_appearance") private var appearance = "system"

    init() {
        UserDefaults.standard.register(defaults: [
            "xm_resume_last_channel": true,
            "xm_appearance": "system"
        ])
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(colorScheme)
                .environment(radioService)
                .task {
                    let region = Locale.current.region?.identifier == "CA" ? "CA" : "US"
                    await radioService.configure(region: region)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await radioService.refreshSessionOnForeground()
                        }
                    }
                }
        }
    }
}
