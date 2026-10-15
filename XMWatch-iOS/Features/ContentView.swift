import SwiftUI

struct ContentView: View {
    @Environment(XMRadioService.self) private var radioService

    var body: some View {
        if !radioService.isConfigured {
            ProgressView("Loading…")
        } else {
            switch radioService.status {
            case .signedOut:
                SignInView()
            case .signingIn:
                ProgressView("Signing in...")
            case .ready:
                MainTabView()
            }
        }
    }
}
