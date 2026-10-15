import SwiftUI

struct XMContentView: View {
    @Environment(XMRadioService.self) private var radioService
    @AppStorage("xm_playback_device") private var playbackDevice = "watch"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                deviceButton("Watch", symbol: "applewatch", value: "watch")
                deviceButton("iPhone", symbol: "iphone", value: "phone")
            }
            .padding(.horizontal, 6)


            if playbackDevice == "phone" {
                PhonePlayerView()
            } else if !radioService.isConfigured {
                ProgressView("Loading…")
            } else {
                switch radioService.status {
                case .signedOut: XMSignInView()
                case .signingIn: ProgressView("Signing in...")
                case .ready: XMTabView()
                }
            }
        }
        .onChange(of: playbackDevice) { _, device in
            if device == "phone" {
                radioService.stopForPhoneMode()
                PlaybackConnectivity.shared.refresh()
            }
        }
    }

    private func deviceButton(_ title: String, symbol: String, value: String) -> some View {
        Button { playbackDevice = value } label: {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(playbackDevice == value ? Color.accentColor : Color.gray.opacity(0.25), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(playbackDevice == value ? .isSelected : [])
    }

}
