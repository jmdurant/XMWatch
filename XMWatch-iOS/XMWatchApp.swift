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
        _ = MetaGlassesAudioPlayerController.shared
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
                    #if DEBUG
                    // The hosted DAT tests must not sign in or auto-resume live radio.
                    if ProcessInfo.processInfo.environment["XM_SKIP_STARTUP_FOR_TESTS"] == "1" { return }
                    #endif
                    PlaybackConnectivity.shared.start(service: radioService)
                    let region = Locale.current.region?.identifier == "CA" ? "CA" : "US"
                    await radioService.configure(region: region)
                }
                .onOpenURL { url in
                    Task { _ = await MetaGlassesAudioPlayerController.shared.handleOpenURL(url) }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        PlaybackConnectivity.shared.refresh()
                        Task {
                            await radioService.refreshSessionOnForeground()
                        }
                    }
                }
        }
    }
}
