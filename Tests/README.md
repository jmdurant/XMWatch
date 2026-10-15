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
