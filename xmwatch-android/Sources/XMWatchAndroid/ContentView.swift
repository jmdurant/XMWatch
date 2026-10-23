import SwiftUI
import XMRadioCore

struct ContentView: View {
    @State var model = ViewModel.shared
    @Environment(\.scenePhase) var scenePhase
    var body: some View {
        content.preferredColorScheme(model.appearance.colorScheme)
            .task { await model.restoreAndMonitor() }
            .onAppear { model.setCatalogForeground(scenePhase == .active) }
            .onChange(of: scenePhase, initial: true) { _, phase in model.setCatalogForeground(phase == .active) }
            .onDisappear { model.setCatalogForeground(false) }
            .sheet(isPresented: $model.showChannelPicker) {
                NavigationStack {
                    VStack(spacing: 8) {
                        if let message = model.automationMessage { Text(message).font(.caption).padding(.horizontal) }
                        RadioChannelListView(model: model, favoritesOnly: false)
                            .searchable(text: $model.query, prompt: "Channel, number, category, artist, or song")
                    }.navigationTitle("Tune Channel")
                        .toolbar { Button("Done") { model.showChannelPicker = false } }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if model.account == nil {
            NavigationStack { RadioAccountView(model: model).navigationTitle("XMWatch") }
        } else {
            TabView(selection: $model.selectedTab) {
                NavigationStack {
                    VStack(spacing: 0) {
                        RadioChannelListView(model: model, favoritesOnly: false)
                            .searchable(text: $model.query, prompt: "Channel, number, category, artist, or song")
                            .frame(maxHeight: .infinity)
                        RadioPlaybackAccessory(model: model)
                    }.navigationTitle("Channels")
                }.tabItem { Label("Channels", systemImage: "list.bullet") }.tag("channels")
                NavigationStack {
                    VStack(spacing: 0) {
                        RadioChannelListView(model: model, favoritesOnly: true)
                            .frame(maxHeight: .infinity)
                        RadioPlaybackAccessory(model: model)
                    }.navigationTitle("Favorites")
                }.tabItem { Label("Favorites", systemImage: "star.fill") }.tag("favorites")
                NavigationStack { RadioNowPlayingView(model: model).navigationTitle("Now Playing") }
                    .tabItem { Label("Now Playing", systemImage: "play.fill") }.tag("player")
                NavigationStack {
                    VStack(spacing: 0) {
                        RadioSettingsView(model: model).frame(maxHeight: .infinity)
                        RadioPlaybackAccessory(model: model)
                    }.navigationTitle("Settings")
                }.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag("settings")
            }
        }
    }

}

struct RadioAccountView: View {
    @State var model: ViewModel

    var body: some View {
        let busy = model.busy
        let restoring = model.restoringSession
        let retrySession = model.canRestoreSession
        let retryChannels = model.canRetryChannels
        let error = model.errorMessage
        Form {
            if restoring { ProgressView("Restoring saved session…") }
            else if busy { ProgressView("Signing in and loading channels…") }
            if let error { Text(error).foregroundStyle(.red) }
            if retrySession {
                Button("Retry Saved Session") { model.restoreSavedSession() }.disabled(busy)
            }
            if retryChannels {
                Button("Retry Loading Channels") { model.retryChannels() }.disabled(busy)
            }
            Section("SiriusXM account") {
                Picker("Region", selection: Binding(get: { model.region }, set: { model.switchRegion($0) })) {
                    Text("United States").tag(RadioRegion.us)
                    Text("Canada").tag(RadioRegion.canada)
                }
                TextField("Username or email", text: $model.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $model.password)
                Button("Sign In") { model.signIn() }
                    .disabled(busy || model.username.isEmpty || model.password.isEmpty)
            }.disabled(busy)
            RadioDiagnosticsView(model: model)
            Text("Sign in with your SiriusXM streaming subscription.")
        }
    }
}

struct RadioSettingsView: View {
    @State var model: ViewModel

    var body: some View {
        let account = model.account ?? ""
        let resume = model.resumeLastChannel
        let appearance = model.appearance
        Form {
            Section("Playback") {
                Toggle("Resume Last Channel", isOn: Binding(get: { resume }, set: { model.resumeLastChannel = $0 }))
                Text("Automatically play your last channel when XMWatch opens.").font(.caption)
                #if os(Android)
                Button("Meta Glasses") { MetaGlassesLink.open() }
                Button("Audio Output") { _ = AudioOutputLink.open() }
                #endif
            }
            Section("Appearance") {
                Picker("Appearance", selection: Binding(get: { appearance }, set: { model.appearance = $0 })) {
                    Text("System").tag(AppAppearance.system)
                    Text("Light").tag(AppAppearance.light)
                    Text("Dark").tag(AppAppearance.dark)
                }
            }
            Section("Region") {
                Picker("Region", selection: Binding(get: { model.region }, set: { model.switchRegion($0) })) {
                    Text("United States").tag(RadioRegion.us)
                    Text("Canada").tag(RadioRegion.canada)
                }.disabled(model.busy)
                Text("Each region keeps its own saved session, favorites, and last channel. A region without a saved session requires sign-in.").font(.caption)
                if model.busy { ProgressView("Switching region…") }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            RadioDiagnosticsView(model: model)
            Section("Account") {
                Text(account)
                Button("Sign Out", role: .destructive) { model.signOut() }
            }
        }
    }
}

struct RadioChannelListView: View {
    let model: ViewModel
    let favoritesOnly: Bool

    var body: some View {
        let channels = favoritesOnly
            ? model.channels.filter { model.favorites.contains($0.id) }
            : model.filteredChannels
        let categories = model.categories
        let category = model.selectedCategory
        let busy = model.busy
        let error = model.catalogError
        VStack(spacing: 0) {
            if !favoritesOnly {
                Picker("Category", selection: Binding(get: { category }, set: { model.selectedCategory = $0 })) {
                    Text("All Categories").tag("")
                    if !categories.isEmpty {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                }.pickerStyle(.menu).padding(.horizontal)
                    .accessibilityLabel("Channel Category")
                if busy { ProgressView("Refreshing channels…").padding(8) }
                if let error { Text(error).foregroundStyle(.red).font(.caption).padding(8) }
            }
            if channels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: favoritesOnly ? "star.fill" : "list.bullet").font(.largeTitle)
                    Text(favoritesOnly ? "No Favorites Yet" : "No Matching Channels").font(.headline)
                    if favoritesOnly { Text("Tap a channel's star to add it here.").foregroundStyle(.secondary) }
                    else {
                        Button("Clear Filters") { model.query = ""; model.selectedCategory = "" }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(channels) { channel in RadioChannelRow(model: model, channel: channel) }
                    .refreshable { await model.refreshCatalog() }
            }
        }
        .toolbar {
            if !favoritesOnly { Button("Refresh") { Task { await model.refreshCatalog() } }.disabled(busy) }
        }
    }
}

struct RadioChannelRow: View {
    let model: ViewModel
    let channel: RadioChannel

    var body: some View {
        let favorite = model.favorites.contains(channel.id)
        let current = model.currentChannel?.id == channel.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { model.play(channel) } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: channel.artworkURL) { image in image.resizable().scaledToFit() }
                            placeholder: { Image(systemName: "list.bullet").foregroundStyle(.secondary) }
                            .padding(4).frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.88)).clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text("\(channel.number) · \(channel.name)").lineLimit(2)
                            Text(channel.category).font(.caption).foregroundStyle(.secondary)
                        }
                        if current { Image(systemName: "play.fill").font(.caption).accessibilityHidden(true) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderless).accessibilityLabel("Play \(channel.name)")
                Button { model.toggleFavorite(channel) } label: {
                    Image(systemName: "star.fill").opacity(favorite ? 1 : 0.35)
                }.buttonStyle(.borderless).accessibilityLabel("Favorite \(channel.name)")
            }
            if let preview = model.channelPreviews[channel.id] {
                if let title = preview.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel("Current song: \(title)")
                }
                if let artist = preview.artist, !artist.isEmpty {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel("Current artist: \(artist)")
                }
            }
        }
        .contextMenu {
            #if os(Android)
            Button("Add Channel Shortcut") { model.pinChannelShortcut(channel) }
            #endif
        }
    }
}


/// Available before sign-in so failed authentication can be diagnosed too.
struct RadioDiagnosticsView: View {
    let model: ViewModel

    var body: some View {
        Section("Diagnostics") {
            Toggle("Debug Mode", isOn: Binding(get: { model.debugMode }, set: { model.debugMode = $0 }))
            if model.debugMode {
                Text("Shows request stages, status codes and counts. Account details, cookies, passwords and stream addresses are excluded. The last 80 messages stay in memory until cleared or Debug Mode is turned off.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.diagnosticMessages.isEmpty {
                    Text("No diagnostic messages yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.diagnosticMessages.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                    Button("Clear Diagnostics") { model.clearDiagnostics() }
                }
            }
        }
    }
}
