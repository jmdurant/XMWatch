Playback regression tests compile each app's real `XMRadioService` against controlled HTTP responses and lightweight player/proxy doubles. They run on macOS without an account, simulator, or physical device. They cover cancellation, channel ordering, remote command callbacks, sign-out, refresh coalescing/retry, and current/stale metadata.

```sh
mkdir -p /tmp/XMWatchRegression
xcodegen generate --spec Tests/project.yml --project /tmp/XMWatchRegression
xcodebuild -project /tmp/XMWatchRegression/XMWatchRegression.xcodeproj \
  -scheme PlaybackRegression -destination 'platform=macOS' test
```

The device controllers and system remote command registration are verified by building the app targets. Physical-device checks still needed: lower wrist/lock phone during extended playback, disconnect Bluetooth, interrupt with another audio app, pause during a network outage, and resume after a long pause. Confirm the displayed song follows the audible stream on music and talk channels.
