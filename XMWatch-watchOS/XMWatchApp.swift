import SwiftUI
import StarPlayrRadioKit

@main
struct XMWatchApp: App {
    @State private var radioService = XMRadioService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: [
            "xm_resume_last_channel": true
        ])
    }

    var body: some Scene {
        WindowGroup {
            XMContentView()
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
