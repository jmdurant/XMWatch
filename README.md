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
