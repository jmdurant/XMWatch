# XMWatch - watchOS SiriusXM Radio Client

A native watchOS companion for StarPlayrX, bringing SiriusXM radio to Apple Watch. Built by adapting the proven streaming infrastructure from [Strimr](https://github.com/nicemac/strimr) (a watchOS Plex client) and wiring it to StarPlayrRadioKit's SiriusXM API layer.

## Features

- **Direct Authentication** - Username/password login right on the watch, no iPhone needed
- **Channel Browser** - Browse all SiriusXM channels by category with search
- **Live Radio Playback** - HLS streaming via local proxy server with AES decryption
- **Now Playing** - Real-time song/artist info with album art from PDT (Program Data Tags)
- **Lock Screen Controls** - Play/pause and channel skip via MPRemoteCommandCenter
- **Background Audio** - Audio continues when navigating away from the app
- **Favorites** - Star channels for quick access, persisted across launches
- **Token Management** - Automatic SXMAKTOKEN refresh every 480 seconds
- **Region Support** - US and Canada SiriusXM endpoints

## Architecture

```
SwiftUI Views (adapted from Strimr)
XMWatchApp -> XMContentView -> XMTabView
XMPlayerView | XMChannelsView | XMFavoritesView | XMSettingsView
        |
XMRadioService (@Observable)
async/await wrapper around StarPlayrRadioKit
Login, Session, Channels, NowPlaying, PDT
        |
XMHLSProxyServer (adapted from Strimr)
NWListener on localhost, injects auth tokens,
rewrites m3u8, serves AES keys
        |
AVPlayer (WatchAVPlayerController)
HLS playback, background audio, Now Playing
```

## Implementation

### Player Infrastructure (from Strimr)

The player layer is adapted from Strimr's production watchOS code:

- **PlayerCoordinating** - Protocol defining play, pause, seek, track selection
- **WatchAVPlayerController** - AVPlayer wrapper with KVO observers, audio session configured for `.longFormAudio`
- **WatchNowPlayingManager** - MPRemoteCommandCenter integration adapted for live radio (no seek, channel skip instead of track skip, `isLiveStream = true`)

### Service Layer (new)

- **XMRadioService** - `@MainActor @Observable` class wrapping all StarPlayrRadioKit APIs. All synchronous semaphore-based RadioKit calls are dispatched via `Task.detached {}` to avoid blocking the main actor. Manages auth state, channel list, now-playing metadata, favorites (UserDefaults), and token refresh timing.

### HLS Proxy (adapted from Strimr)

- **XMHLSProxyServer** - `NWListener`-based localhost HTTP server handling three route types:
  - `/{channelNumber}.m3u8` - Fetches playlist via `Playlist()`, rewrites key/segment URLs to localhost
  - `/aac/{segment}` - Proxies audio segments via `AudioX()` with auth tokens
  - `/key` - Serves base64-decoded AES decryption key from `userX.key`

The m3u8 rewriting logic is ported from StarPlayrRadioKit's `playlistRoute.swift`, replacing `key/1` with `/key` and prefixing segment references with `/aac/`.

### StarPlayrRadioKit Changes

- Added `.watchOS("26.0")` platform to `Package.swift` (bumped swift-tools-version to 5.7)
- Added `#if !os(watchOS)` guards to all 11 Route files (SwifterLite server code excluded from watchOS)
- Made 16+ internal functions/variables `public` for cross-module access
- Made all Codable model structs `public` (`DiscoverChannelList`, `NowPlayingLiveStruct`, etc.)

### SwifterLite Changes

- Added `.watchOS("26.0")` platform to `Package.swift` (bumped swift-tools-version to 5.7)

## File Structure

```
XMWatch-watchOS/
├── Package.swift
├── XMWatchApp.swift                         # App entry point
├── Info.plist                               # Background audio mode
├── XMWatch-watchOS.entitlements             # Network client entitlement
│
├── Services/
│   ├── XMRadioService.swift                 # Core service: login, channels, streaming, PDT
│   └── XMHLSProxyServer.swift               # HLS proxy with SiriusXM auth injection
│
├── Player/
│   ├── PlayerCoordinating.swift             # Protocol (from Strimr Shared)
│   ├── PlayerProperty.swift                 # Enum (from Strimr Shared)
│   ├── PlayerTrack.swift                    # Struct (from Strimr Shared)
│   ├── PlayerOptions.swift                  # Struct (from Strimr Shared)
│   ├── WatchAVPlayerController.swift        # AVPlayer wrapper (from Strimr)
│   └── WatchNowPlayingManager.swift         # MPRemoteCommandCenter (adapted for XM)
│
├── Features/
│   ├── XMContentView.swift                  # Root: auth state router
│   ├── XMTabView.swift                      # 4-tab navigation
│   ├── Auth/
│   │   └── XMSignInView.swift               # Username/password login
│   ├── Player/
│   │   └── XMPlayerView.swift               # Now playing: art, artist, song, controls
│   ├── Channels/
│   │   └── XMChannelsView.swift             # Channel browser with categories + search
│   ├── Favorites/
│   │   └── XMFavoritesView.swift            # Saved/starred channels
│   └── Settings/
│       └── XMSettingsView.swift             # Region, account, sign out
│
└── Models/
    └── XMChannel.swift                      # Channel model for SwiftUI
```

## Building

```bash
# Build for watchOS device
swift build --sdk .../WatchOS.sdk --triple arm64-apple-watchos26.0

# Build for watchOS Simulator
swift build --sdk .../WatchSimulator.sdk --triple arm64-apple-watchos26.0-simulator
```

## Future Plans

- **VLCKit Integration** - Adapt Strimr's `WatchVLCPlayerController` for offline audio playback with audio visualization bridge
- **Audio Visualizations** - Port Strimr's `WatchVisualizationView` spectrum analyzer for a visual EQ display during playback
- **Xcode Target** - Add proper watchOS target to the SPX workspace for single-click build/run
- **Complications** - watchOS complications showing current channel and now-playing info
- **Handoff** - Continue listening when switching between watch, iPhone, and Mac

## Requirements

- watchOS 26+
- Apple Watch Series 10 or later / Apple Watch Ultra 2 or later
- Valid SiriusXM subscription
- Internet connection

## Credits

- Player infrastructure adapted from [Strimr](https://github.com/nicemac/strimr) watchOS Plex client
- SiriusXM API layer powered by StarPlayrRadioKit
- Built with SwiftUI, AVFoundation, Network.framework, and MediaPlayer
