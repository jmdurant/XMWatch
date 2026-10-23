## Android port (in progress)

`xmwatch-android` is the native Swift/Skip Android app. `XMRadioCore` contains the
portable SiriusXM request builder, authenticated HTTP client, and channel parser.
The app covers sign-in, region selection, channel search, local favorites, live HLS
audio, Now Playing controls, and encrypted cookie-session restoration. Streaming
recovery and current-song metadata are implemented. Live checks passed eight-minute
session renewal, stream recovery, search/favorites, and optimized-release background
playback/system controls on the ARM64 emulator. App/system next/previous and actual
notification navigation also passed on the optimized build. Full Android parity is
still in progress. Saved-cookie retry and opt-in last-channel resumption also
passed emulator UI checks. Category browsing, catalog refresh/retry, Light/Dark
appearance, and corrected HTTPS channel logos are implemented and verified.
Android Auto/media controllers now browse all channels, favorites and categories,
search/select channels by voice, read local cover art and resume the saved channel
after a cold start using the existing encrypted cookie. Emulator checks cover
459 channels and both approved and rejected external clients; physical head-unit
testing and Android glasses remain unfinished. Wear OS is outside the scope.
See [Android development](xmwatch-android/README.md).

The current Android implementation also adds per-channel song and artist previews
to channel lists, with the same name/number/category/song/artist search rules on
the phone and connected media controllers. One bulk request refreshes the catalog
every 30 seconds while foregrounded and on demand for controller browsing;
requests share a 30-second throttle. Entries expire after 90 seconds without a
successful update, and account/region changes discard older replies. These
listing previews stay separate from the audible channel's Now Playing timeline.

A mini player now stays available across Channels, Favorites and Settings, with
current artwork/metadata, connection status, play/pause and an entry to Now Playing.
Now Playing adapts its artwork and controls to portrait or landscape space.
This debug batch passed 29 shared checks on both macOS and native Android, a
saved-cookie live song/artist search check, and decoded playback with mini-player
navigation and landscape play/pause. Private preferences/cookies were restored
and installed APK hashes verified. Physical devices, the current optimized build,
a real Canadian account and an Android Auto artist-query check remain unverified.

## XMWatch for iPhone and Apple Watch

The `XMWatch-iOS` and `XMWatch-watchOS` folders contain the newer native radio apps. Generate the combined iPhone/watch project with `xcodegen generate --spec XMWatch-iOS/project.yml`, then open `XMWatch-iOS/XMWatch-iOS.xcodeproj`. Playback regression and simulator test instructions are in [Tests/README.md](Tests/README.md).

XMWatch on iPhone supports **Meta Ray-Ban Display** through Meta Wearables DAT **1.0.1**, using the same discovery, registration, connection lifecycle, and retained-error handling as Cadence and Slingshot. In **Settings → Meta Glasses**, register with Meta AI, install/update the DAT app on the glasses, then connect. Keep the glasses on and unfolded, with Bluetooth connected and Developer Mode enabled in Meta AI. The screen lists discovered devices and offers separate DAT app and firmware update actions.

Start a channel on the iPhone to show the current song, artist, channel, and live playback status on the glasses. **Previous / Play or Pause / Next** controls the iPhone's channel player. Pausing also cancels tuning/reconnection. Audio follows the iPhone's selected output; choose glasses in the Now Playing audio output picker to hear it there. Glasses without a display can use Bluetooth audio but cannot show this player. Apple Watch retains its standalone and iPhone-control modes; the DAT SDK belongs only to the iOS target.

The checked-in Meta configuration uses developer mode (`MetaAppID = 0`, callback `xmwatch://`). Distribution requires the app's real Meta App ID and `MWDAT_CLIENT_TOKEN`, with its bundle ID, signing team, and callback registered in the Meta developer dashboard. Do not commit credentials. Mock tests verify discovery, reconnects, error retention, and radio commands without an account; real-glasses registration, display/input, audio routing, and locked-phone operation still need hardware verification.

---

Important: StarPlayrX was developed for the Visually Impaired, a group of paying subscribers that SiriusXM has classsically ignored.

Update: macOS 26 static, hisses and popping sounds fix with AVPlayer,

while playing run this in the terminal

`sudo killall coreaudiod`
https://medium.com/tech-blog-today/how-to-fix-popping-sounds-on-macos-26-c2846fc65ad0

# 🚨 StarPlayrX 1.3.1
- macOS Doomsday Edition

## System Requirements
- macOS 14.5 and later
- Mac with Apple Silicon or Intel processor
- Valid SiriusXM subscription

## 🖥️ Interface Design
- Native Mac Catalyst application
- Unified sidebar and title bar design
- Adaptive layout for various Mac screen sizes
- Optimized for both large displays and smaller MacBook screens

## 🌟 Key Features
- Seamless SiriusXM radio streaming
- Light and dark mode support
- Efficient resource management
- 100% VoiceOver compatibility
- Minimal network resource utilization

## 🔧 Technical Specifications
- Primary Language: Swift (90%)
- Secondary Language: Objective-C (10%)
- Platforms: macOS, (iOS, iPadOS, must build locally due to SXM's recent distribution restrictions)
- Development: Xcode 16 Workspace

## 🚀 Performance Highlights
- Low latency streaming
- Minimal CPU and memory footprint
- Smooth playback across network conditions

## ⚠️ Usage Notes
- Requires active SiriusXM subscription
- Internet connection mandatory for streaming

## 📦 Deployment
- Signed and Notarized by Apple
- Available on Github Releases Side Bar

## Licensing
- StarPlayr Trademark is owned by NiceMac LLC
- All material is Copyright 2025-2026 by StarPlayrX.com
- This trademark is licensed exclusively to StarPlayrX.com
- NiceMac LLC is not associated with SiriusXM or its subsidiaries

**StarPlayrX Doomsday**: https://starplayrx.com

Don't be a slacker, be a Star Player.

F. S. X. M. for ignoring the visually impaired.

Android connected-browser updates now refresh subscribed Favorites/catalog folders without reconnecting. Verified with 22 native tests and a saved-cookie live browser/UI check on CadenceCarLibrary; exact account/preferences restoration passed. See `xmwatch-android/README.md` and `build/android/checkpoints/catalog-updates-20261022/`.
