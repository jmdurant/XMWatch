import SwiftUI

struct XMContentView: View {
    @Environment(XMRadioService.self) private var radioService

    var body: some View {
        switch radioService.status {
        case .signedOut:
            XMSignInView()
        case .signingIn:
            ProgressView("Signing in...")
        case .ready:
            XMTabView()
        }
    }
}
