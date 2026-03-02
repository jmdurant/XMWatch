import SwiftUI
import StarPlayrRadioKit

@main
struct XMWatchApp: App {
    @State private var radioService = XMRadioService()
    @Environment(\.scenePhase) private var scenePhase

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
