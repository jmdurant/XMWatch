# XMRadioCore

A Foundation-only Swift package for XMWatch's SiriusXM client. The Android app uses
this package directly; the existing Apple apps still use StarPlayrRadioKit and their
platform services. No AVFoundation, Objective-C key paths, or local HTTP server is
required by this package. Both macOS and native ARM64 Android run the same tests.

`RadioClient` owns an isolated, explicit cookie jar. Its login sequence authenticates,
establishes a live session, then allows channel discovery. A saved cookie snapshot can
restore that sequence without a password. The caller supplies secure snapshot storage;
XMWatch Android encrypts it using an Android Keystore key. No password is serialized.

`playbackPlan(channelID:bitrate:)` obtains provider configuration, refreshes the live
session, and resolves the playlist and segment routes with their AES key. Its encoded
plan contains private transport material and stays inside the playback adapter. The
Android adapter publishes opaque media URIs and ordinary channel/song metadata.

`nowPlaying(channelID:audibleDate:)` selects a cut on the audible playback timeline.
The parser supports epoch and ISO timestamps, including the provider's `+0000`
timezone form. A live cut's duration can remain zero until it ends: it stays current
until a newer cut starts. Completed cuts still end at their specified duration, and
promos/gaps clear stale song fields. Album-art placeholders become HTTPS URLs.

Channel artwork normalizes Discovery's legacy primary/secondary image hosts to
`https://albumart.siriusxm.com`, preserving their public image paths. The legacy
hostname does not present a matching HTTPS certificate; a scheme-only upgrade is
insufficient. Other trusted SiriusXM HTTP image URLs become HTTPS. File URLs,
lookalike HTTP domains, and URLs containing credentials are rejected. The Android
channel list and system metadata therefore share usable HTTPS artwork.

Run the fixture suite from the repository root:

```sh
swift test --package-path XMRadioCore --jobs 2
bash scripts/test-radio-core-android.sh --serial emulator-5560
```

There are 22 tests (23 cases including both regions), covering request/response
handling, cookies, restored sessions, stream plans, metadata boundaries, and the
open-ended live-cut behavior observed in real SiriusXM responses. Live playback and
Android service checks are documented in `../xmwatch-android/README.md`.
