import SwiftUI

struct XMContentView: View {
    @Environment(XMRadioService.self) private var radioService
    @AppStorage("xm_playback_device") private var playbackDevice = "watch"

    var body: some View {
        Group {
            if playbackDevice == "phone" {
                PhonePlayerView()
            } else if !radioService.isConfigured {
                ProgressView("Loading…")
            } else {
                switch radioService.status {
                case .signedOut:
                    VStack {
                        XMPlaybackDevicePicker()
                        XMSignInView()
                    }
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

}
