import SwiftUI
import WatchKit

struct XMPlayerView: View {
    @Environment(XMRadioService.self) private var radioService

    var body: some View {
        ScrollView {
            if let channel = radioService.currentChannel {
                VStack(spacing: 10) {
                    // Album art or channel logo
                    if let artURL = radioService.nowPlayingArtURL, let url = URL(string: artURL) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            channelImage(channel)
                        }
                        .frame(width: 80, height: 80)
                        .cornerRadius(8)
                    } else {
                        channelImage(channel)
                    }

                    // Song title + Artist
                    VStack(spacing: 2) {
                        if radioService.isReconnecting {
                            ProgressView()
                                .padding(.bottom, 2)
                            Text(channel.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text("Reconnecting…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if radioService.isBuffering {
                            ProgressView()
                                .padding(.bottom, 2)
                            Text(channel.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text("Tuning Ch. \(channel.number)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(radioService.nowPlayingSong ?? channel.name)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)

                            Text(radioService.nowPlayingArtist ?? "Ch. \(channel.number)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Controls
                    HStack(spacing: 20) {
                        Button {
                            Task { await radioService.previousChannel() }
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        Button {
                            radioService.togglePlayback()
                        } label: {
                            Image(systemName: !radioService.userWantsPlayback ? "play.fill" : "pause.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await radioService.nextChannel() }
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "radio")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Channel Selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Choose a channel from the Channels tab")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .navigationTitle("Now Playing")
        .watchPlaybackVolume(.local, isReady: !radioService.isBuffering)
    }

    @ViewBuilder
    private func channelImage(_ channel: XMChannel) -> some View {
        AsyncImage(url: URL(string: channel.mediumImageURL)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "radio")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 80, height: 80)
        .cornerRadius(8)
    }
}

// Keep the system volume control visible and focused while this playback screen is active.
// WatchKit owns the actual watch/iPhone volume; no per-player gain or custom volume RPC.
@MainActor
extension View {
    func watchPlaybackVolume(_ origin: WKInterfaceVolumeControl.Origin, isReady: Bool = true) -> some View {
        modifier(WatchPlaybackVolumeModifier(origin: origin, isReady: isReady))
    }
}

@MainActor
private final class WatchVolumeFocus {
    weak var control: WKInterfaceVolumeControl?
    var visible = false
    var sceneActive = false
    private var ownsFocus = false

    func refresh() {
        guard let control else { return }
        if visible && sceneActive {
            control.focus()
            ownsFocus = true
        } else { release() }
    }

    private func release() {
        // Repeated resigns during teardown can clear the next screen's new focus.
        guard ownsFocus else { return }
        ownsFocus = false
        control?.resignFocus()
    }

    func detach(_ control: WKInterfaceVolumeControl) {
        guard self.control === control else { return }
        release()
        self.control = nil
    }
}

@MainActor
private struct WatchNativeVolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin
    let focus: WatchVolumeFocus

    func makeCoordinator() -> WatchVolumeFocus { focus }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: origin)
        focus.control = control
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        // Wait for the native control to join the interface before requesting Crown input.
        DispatchQueue.main.async { [weak focus] in focus?.refresh() }
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: WatchVolumeFocus) {
        coordinator.detach(control)
    }
}

@MainActor
private struct WatchPlaybackVolumeModifier: ViewModifier {
    let origin: WKInterfaceVolumeControl.Origin
    let isReady: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var focus = WatchVolumeFocus()

    func body(content: Content) -> some View {
        content
            .focusable(false)
            .safeAreaInset(edge: .bottom, spacing: 2) {
                WatchNativeVolumeControl(origin: origin, focus: focus)
                    .frame(height: 32)
                    .accessibilityLabel(origin == .local ? "Apple Watch volume" : "iPhone volume")
                    .accessibilityIdentifier(origin == .local ? "watch.volume.local" : "watch.volume.phone")
                    .background(.background)
            }
            .onAppear {
                focus.visible = true
                focus.sceneActive = scenePhase == .active
                focus.refresh()
            }
            .onDisappear { focus.visible = false; focus.refresh() }
            .onChange(of: isReady) { _, ready in if ready { focus.refresh() } }
            .onChange(of: scenePhase) { _, phase in
                focus.sceneActive = phase == .active
                focus.refresh()
            }
            // Restore Crown ownership after a finger scroll finishes without intercepting it.
            .onScrollPhaseChange { _, phase in
                if phase == .idle { focus.refresh() }
            }
    }
}
