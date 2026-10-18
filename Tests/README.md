Playback regression tests compile each app's real `XMRadioService` against controlled HTTP responses and lightweight player/proxy doubles. They run on macOS without an account, simulator, or physical device. They cover cancellation, channel ordering, remote command callbacks, sign-out, refresh coalescing/retry, current/stale metadata, startup ordering, retry backoff across player replacements, and phone-state snapshot ordering.

```sh
mkdir -p /tmp/XMWatchRegression
xcodegen generate --spec Tests/project.yml --project /tmp/XMWatchRegression
xcodebuild -project /tmp/XMWatchRegression/XMWatchRegression.xcodeproj \
  -scheme PlaybackRegression -destination 'platform=macOS' test
```

The device controllers and system remote command registration are verified by building the app targets. Physical-device checks still needed: lower wrist/lock phone during extended playback, disconnect Bluetooth, interrupt with another audio app, pause during a network outage, and resume after a long pause. Confirm the displayed song follows the audible stream on music and talk channels.

The watch's **Watch / iPhone** selector chooses local streaming or a remote display/controller. iPhone mode works without a watch login. Switching to iPhone stops the watch player and cancels its pending recovery. Remote commands are never queued for later delivery. Explicit Siri channel requests start standalone watch playback; generic play/pause/skip commands follow the selected source.

Paired-device checks for the new mode: start a channel on iPhone and compare title/art/state on watch; pause/resume and skip from watch; disconnect/reconnect the phone and confirm cached state is labeled and commands are disabled; sign out on iPhone and confirm the watch clears metadata; switch to iPhone while the watch is tuning and confirm no local restart occurs.

## Meta glasses simulator tests

The iOS project's `XMWatchMetaTests` target uses Meta DAT 1.0.1 `MockDeviceKit` against the real controller. It covers discovery after tapping Connect, duplicate taps, disconnect/reconnect, terminal errors, timeout and cancellation, unsupported glasses, registration gating, unavailable SDK configuration, and the host app's Bluetooth/background/callback configuration. Radio-specific tests exercise the actual DAT button callbacks, ignore commands from an old connection or after clearing the channel, and check song/channel fallbacks and playback intent during buffering/recovery.

From the repository root, choose an installed iPhone simulator (`xcrun simctl list devices available`) and run:

```sh
xcodegen generate --spec XMWatch-iOS/project.yml
xcodebuild -project XMWatch-iOS/XMWatch-iOS.xcodeproj \
  -scheme XMWatch-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The test scheme sets `XM_SKIP_STARTUP_FOR_TESTS=1` in Debug, bypassing SiriusXM startup and auto-resume only for this test run. Tests use a radio playback spy and need no login or hardware. Keep the default simulator code signing enabled; DAT initialization uses the keychain. Run serially: MockDeviceKit is a process-wide SDK override. It is linked only into the test bundle. These tests supplement the macOS phone/watch regressions above; they do not verify Bluetooth radio conditions or real Meta AI registration.

Physical glasses check: use the signed iPhone app, enable Developer Mode in Meta AI, and open **Settings → Meta Glasses**. Register, update the DAT glasses app and firmware as needed, then connect with the display glasses unfolded and worn. Start a channel on iPhone, compare the song/artist/channel, pause and resume from the glasses, and switch channels both ways. Try pausing during tuning, sign out and verify controls clear, fold/unfold and reconnect, then verify updates and commands with the iPhone locked. Choose glasses in the phone's audio output picker separately. Confirm ordinary non-display glasses show a useful explanation. Apple Watch streaming and iPhone controls should continue to work alongside the glasses.
