# XMWatch Android

Native Swift with Skip Fuse UI, reusing the toolchain approach verified in Cadence.
Application ID: `com.doctordurant.xmwatch.android`. The Android project is independent
of the existing Xcode projects; the Apple radio implementation has not been switched
to the new client yet. The current Android minimum is API 29 (Android 10).

## Current scope

- `../XMRadioCore`: portable US/Canada requests, explicit cookies, session validation,
  channel parsing, stream configuration and playback plans.
- Sign-in, channel search, local favorites, automatic navigation to Now Playing,
  channel artwork, previous/next channel, pause and reconnect.
- Per-channel current song/artist previews from one bulk Discovery request, shared
  phone/controller search by channel, number, category, song and artist, and a mini
  player across browsing/settings with an adaptive Now Playing layout. These
  additions passed debug emulator metadata/search and decoded playback/layout checks.
- Android Media3 HLS audio and a foreground media service with system controls.
  The source routes AES keys and authorized audio segments privately. System
  media items use opaque `xmwatch://` addresses rather than provider credentials.
- Android Auto/media-library browsing for all channels, favorites and categories,
  paged channel lists, search/voice selection, local cover art and cold playback
  resumption. External callers use the same installed-identity policy as Cadence
  and Slingshot; channel preparation stays silent until Play.
- Existing session cookies are encrypted with an Android Keystore AES-GCM key.
  App startup restores and revalidates them before loading channels. Passwords are
  cleared after an attempt and never persisted. Sign-out removes the saved session.
- Live authentication, channel loading, and initial streaming have worked on the
  ARM64 emulator. The live harness passed decoded audio, background playback,
  foreground service, system pause/resume, channel switching, and cold restoration.

Current-song metadata, timed token renewal, and stream recovery are implemented.
Their current live verification is recorded below. Remaining phone work includes
physical-device/headset and Android Auto head-unit checks, physical Android glasses and
further integration polish. Wear OS is outside the current scope.

## Phone parity audit (October 22, 2026)

The current Apple phone implementation and Android phone implementation cover the
same core radio features. This is a source audit; earlier checkpoint results apply
only to their recorded builds.

| Apple phone feature | Android implementation | Verification still needed |
| --- | --- | --- |
| Account sign-in and saved-session restoration | User-entered credentials, encrypted cookie vault, cookie-only retry | Current optimized build regression |
| Channels, categories, search and favorites | Shared channel matching, local regional favorites and bulk current-song previews | Real Canadian account |
| Now Playing, artwork and mini player | Live metadata, portrait/landscape player and persistent browsing accessory | Physical phone/headset behavior |
| Pause/resume and previous/next channel | Shared playback intent across app, notification, controller and shortcuts | Live shortcut next/previous; current optimized build |
| Resume Last Channel, appearance and region settings | Persisted preferences and separate encrypted regional sessions | Current optimized build |
| Audio routing | Android system output chooser with settings fallback | Real Bluetooth route changes; API 29–33 fallback |
| Meta display integration | DAT 1.0.1 display metadata and radio controls | Physical display glasses, registration and locked-phone behavior |
| Debug Mode and sign-in diagnostics | Opt-in request-stage/status/count log in Settings and sign-in | Optimized on/off cold-start persistence passed |

Debug Mode is off by default. The diagnostic list holds at most 80 messages of
512 characters in memory; disabling Debug Mode or signing out clears it. Provider
summaries exclude accounts, cookies, passwords, request bodies and stream URLs.
The setting survives relaunch; message history does not. Basic native lifecycle
logs remain independent of this provider-diagnostics setting.

Android Auto and foreground launcher shortcuts are additional Android features;
they are not Google Assistant App Actions. Wear OS is outside scope. No new radio
product feature was identified as missing beyond the diagnostics UI added in this
audit. Current release verification and physical hardware checks remain necessary
before declaring full parity.

The focused optimized harness freezes the tested release and installed debug
APKs, suppresses last-channel autoplay under private-state escrow, toggles Debug
Mode on/off through the actual Swift UI and checks each value after a cold start.
It restores the original debug APK before the guardian restores private files.
The optional playback flag also runs the existing live radio regression using the
saved encrypted session. The current optimized run passed; its exact scope is recorded below.

```sh
python3 scripts/test-radio-optimized-parity-android.py --serial emulator-5560 \
  --release-apk build/android/parity-current/XMWatchAndroid-release.apk \
  --output build/android/evidence/parity-current-optimized --playback
```

The current optimized release build subsequently passed the saved-cookie live
radio regression: real song metadata, 444,822 decoded background audio frames,
foreground service, app/system next and previous channel, system pause/resume,
and notification navigation into Now Playing. No test runtime was injected.
The separate diagnostics check also passed the actual Swift Settings switch:
off → on → cold start still on → off → cold start still off, without starting radio.
Both checks restored the exact previously installed debug APK and all private
preference file variants, removed private escrow, and stopped the app. The UI
harness waits for account restoration to reach signed-in Settings; a transient
sign-in diagnostics form is not treated as the Settings destination.

Frozen release APK/AAB, mapping, build/static checks and successful live playback:
`build/android/checkpoints/phone-parity-release-20261022/`. Diagnostics persistence
and restoration evidence: `build/android/checkpoints/phone-parity-diagnostics-20261022/`.
These checks do not cover physical hardware or a real Canadian account.

The same audit removed hardcoded account credentials from the Apple phone and
watch sign-in screens. Both now request username/password and clear the password
after each attempt. Those actual Apple view files passed SwiftUI type-checks against iOS 17 and
watchOS 10 simulator targets using the installed Apple SDKs. The provider service
was stubbed to isolate API availability; this is not a full project build or live
login test. Rerun with `bash scripts/check-apple-auth-views.sh`. Evidence is under
`build/apple-auth-parity/`. Existing saved sessions were not modified.

## Phone shortcuts and automation

Long-press the app icon for **Tune Channel**, **Pause**, or **Resume**. Tune Channel
opens the searchable channel picker. Favorite channels can appear as additional
launcher entries when capacity permits; **Add Channel Shortcut** on a channel row
requests a pinned shortcut. Published channel shortcuts use public regional channel
identities and are disabled when their region/catalog is unavailable.

Foreground links use `xmwatch://automation/<action>`:

| Action | Parameters |
| --- | --- |
| `pick` | Optional `query` for the channel picker |
| `tune` | Exactly one of `channelID`, `number`, or `query` |
| `pause`, `resume`, `next`, `previous` | No channel selector |

Optional `region=US` or `region=CA` identifies the intended catalog. A region
mismatch or ambiguous query opens the picker instead of silently selecting another
channel. The app restores its saved cookie session. For example,
`xmwatch://automation/tune?number=36&region=US`. Channel IDs are limited to 128
letters, digits, underscores or hyphens; numbers to five digits; query text to 160
characters. Intents are consumed before dispatch and later playback commands cancel
pending tune requests. These foreground actions do not register Google Assistant
App Actions; existing Android Auto/media-session controls remain separate.

The debug emulator checkpoint passed three focused checks and one actual app
integration check covering the Swift channel picker, published shortcut metadata,
cold/warm delivery, activity recreation, invalid input and pause through the real
playback model with an owned inert player/session. Private state and the previous
dynamic/pinned shortcut states were restored. That initial fixture check did not
exercise authenticated channel tuning, physical launcher/pinning or optimized runtime.

Build with `bash scripts/build-android.sh --max-workers=2 :app:assembleDebugAndroidTest`,
then run `bash scripts/test-radio-phone-automation-android.sh --serial emulator-5560 --skip-build`.
Frozen evidence: `build/android/checkpoints/phone-automation-20261022/`.

The subsequent live debug check passed actual tune-by-number, pause and resume
links using the emulator's existing encrypted session. Real decoded audio buffers
advanced both before and after resume; the player, channel and media session token
were retained. Normal live resume obtains a fresh stream plan, so its opaque URL
can change. Private preferences/checkpoints and launcher shortcut states were
restored. Next/previous actions, physical launcher use and optimized runtime remain
outside this live check. Evidence:
`build/android/checkpoints/phone-automation-live-20261022/`.
Rerun: `python3 scripts/test-radio-phone-automation-live-android.py --serial emulator-5560`.

## Audio output (debug and optimized chooser checks passed)

**Now Playing → Audio Output** and **Settings → Playback → Audio Output** open
Android's system media output switcher on API 34 and newer when the app is visible.
The implementation uses the public, no-argument
[MediaRouter2 API](https://developer.android.com/reference/android/media/MediaRouter2#showSystemOutputSwitcher()).
If unavailable or rejected, it opens Bluetooth settings, then Sound settings if
needed, with a message if neither can open. Playback stays with the existing media
session; opening output controls does not select or restart a channel.

The debug emulator check passed through the actual Swift **Settings → Playback →
Audio Output** entry: Android's real system output dialog appeared, Back returned
to the caller, and the owned native player's source, queue and session were
unchanged. No output route was selected and no Bluetooth permission was requested.
Private state was restored and installed app/test APK hashes matched the tested
artifacts.

Evidence: `build/android/evidence/audio-output/verification.json`. Tested hashes:

- Debug APK: `88fb76ab32903d511f23f6176b8cbb4f3537f1a66c5862ec7b8e06bc1cf540a6`
- Test APK: `54c483e1e4e7a303145974c2addf6d69fdbf1af7f7341555c5332ba1ebad2781`

Planned frozen checkpoint:
[audio-output-20261022](../build/android/checkpoints/audio-output-20261022/).

The non-debuggable R8 build also passed the actual Swift Settings entry → Android
SystemUI output chooser → Back flow. The framework-only harness used no SDK mock
or shared runtime libraries. Installed release/helper hashes matched the frozen
artifacts; the exact original debug APK and private preference bytes were restored,
the helper was removed, and the app was stopped. No route was selected or permission
change requested. Static packaging checks covered 54 native libraries and 16 KiB
alignment.

Optimized APK SHA-256:
`95bdc6b15e3ec4e31faf1e90ab614768079a066f3c31c9f3ecb67b5ef4f28857`.
Evidence: `build/android/evidence/audio-output-optimized/verification.json`.
Planned optimized checkpoint:
[audio-output-optimized-20261022](../build/android/checkpoints/audio-output-optimized-20261022/).

The source/queue/session preservation result above remains debug-only. Optimized
playback-state preservation, other current phone features, API 29–33 settings
fallbacks, physical Bluetooth devices and actual route changes remain unverified
by this chooser check.

## Channel previews, shared search and player layout

Channel rows can show the provider's current song and artist independently of
the channel's name and category. Phone search and connected-controller/voice
search use the same matching rules for names, channel numbers, categories, songs
and artists. Controller channel subtitles also include available song/artist
previews, and refreshed data notifies subscribed catalog browsers.

One authenticated bulk Discovery request covers the channel catalog; there is no
per-channel polling. The app refreshes while foregrounded every 30 seconds and
on demand when a controller browses or searches. Both paths share one pending
request and a 30-second throttle. Successful replies replace the preview map;
promos, gaps and missing entries clear old text. Timestamped cuts select the
current marker rather than an announced future song. Undated lists use the
provider's first cut, matching the Apple PDT convention. Previews expire after
90 seconds without a successful update and clear across account/region changes;
request, session and region checks reject late replies. These browsing previews
do not replace the separately synchronized audible Now Playing metadata.

Once a channel is selected, the mini player stays visible beneath Channels,
Favorites and Settings. It shows artwork, available song/artist text, channel
identity and connection progress, with play/pause and **Open Now Playing** actions.
The full player uses a vertical layout in portrait and places artwork alongside
the details and controls when landscape space permits. Both layouts retain the
existing playback commands and offer scrolling in smaller windows.

This debug batch passed 29 shared checks on macOS and native Android. On the
CadenceCarLibrary ARM64 emulator, one saved-cookie UI check verified actual live
song/artist metadata, artist and song searches, exclusion of unmatched channels,
and clearing search without starting playback or signing in. A separate check
decoded live audio, opened Now Playing from the mini player, reached the landscape
controls and exercised play/pause while retaining the channel. Full-player
controls provide visible hit areas at least 44 dp high. Both private preferences and cookie
state were restored, and the installed app/test APK hashes matched the tested files.

Tested debug APK SHA-256:
`e90de3573ce6478909f6cd0b0cea5da448c788c78d3e843666c6bcfcf5d7372d`.
Instrumentation APK SHA-256:
`6ffafde6658ede841aaf87c64be7f5a55c1586ec29acb7232fb68c07e155a5d7`.
An additional 25 native regressions and one US → unsigned-in Canada → restored US
UI regression passed, with private file presence/bytes restored and escrow removed.
Evidence: `build/android/evidence/channel-metadata/`. Checkpoint:
`build/android/checkpoints/channel-previews-playback-20261022/`. Physical devices, runtime on the
current optimized build, a real Canadian account and actual Android Auto
artist-query behavior remain unverified. Earlier optimized checkpoints below
cover their stated builds and do not establish these new features' release coverage.

Development note: the cached native NavigationStack initially retained an empty
mini-player branch after playback started. Each browsing/settings stack now
composes `RadioPlaybackAccessory` unconditionally; the child observes the current
channel and decides whether to show itself. This keeps the cached navigation root
from freezing the initial condition while playback state changes.

## Meta glasses (debug and optimized emulator checks passed)

Settings → Playback → Meta Glasses opens the native Meta Wearables DAT 1.0.1
connection screen. Display controls require Meta Ray-Ban Display hardware; ordinary
Ray-Ban Meta glasses use the phone's existing Bluetooth media audio route. The
display shows song, artist, channel and playback status, with play/pause and channel
changes routed through the existing radio session. Live radio has no seek or rate
controls. DAT camera and microphone streaming are not used.

The Android minimum is API 29. Checked-in Gradle properties default to developer
values (`metaDatAppId=0`, `metaDatClientToken=0`); supply the registered production
values through local Gradle properties or `-PmetaDatAppId=… -PmetaDatClientToken=…`.
Keep tokens out of source control. Registration and device permissions are handled
from the glasses screen.

From the repository root, after building the matching debug app and test APKs:

```sh
bash scripts/test-android-meta-glasses.sh --serial emulator-5560 --skip-build
```

This opt-in harness uses the dedicated CadenceCarLibrary emulator, the real DAT
MockDeviceKit session/renderer/input path, and an owned radio-source fixture. It
preserves every shared preference file, removes test-created preference files, and
verifies restored bytes; durable private escrow remains if restoration fails.
On October 22, 2026, the debug build passed all five checks: four real SDK mock
display/session/input checks and one actual radio binding check proving unsupported
seek/rate commands preserve the single owned source. Private preference presence
and bytes were restored, test-created preference files removed, and escrow removed
after verification. This did not authenticate or tune a live SiriusXM channel.

Evidence is written under `build/android/evidence/meta-glasses/`; the APKs, logs,
verification and source hashes are preserved in
`build/android/checkpoints/meta-glasses-20261022/`.

The optimized, non-debuggable R8 build also passed both permission phases with
four native settings launches: two direct cold launches and two through the real
Swift Settings entry. The harness verified actual SDK initialization matched
Nearby permission, checked the real Swift metadata provider and live-radio
restrictions, and restored the exact original debug APK, preference files, and
permission grant/user flags. Denial used the Android permission dialog; the granted
phase was pregranted by shell. This did not simulate Android saved-Activity-state
restoration, authenticate with Meta AI, tune live radio, or test optimized playback
commands. The framework-only instrumentation adds no shared runtime libraries.

After building the release artifacts and framework harness, run:

```sh
python3 scripts/test-android-optimized-meta-glasses.py --serial emulator-5560 \
  --release-apk build/android/meta-glasses-release/XMWatchAndroid-release.apk \
  --harness-apk build/android/meta-glasses-harness/XMWatchMetaGlassesHarness-debug.apk \
  --mapping build/android/meta-glasses-release/release-symbols/mapping.txt \
  --output build/android/evidence/meta-glasses-optimized
```

Build the helper with `bash scripts/build-android-meta-glasses-harness.sh`.
Optimized artifacts and evidence are frozen under
`build/android/checkpoints/meta-glasses-optimized-20261022/`. Physical glasses,
real Meta AI registration, Bluetooth audio/locked-phone behavior, and actual
optimized glasses display/input remain unverified. Earlier optimized playback
checkpoints below predate this integration.

## Build and tests

Prerequisites: Skip 1.9.16, JDK 21, Swift 6.4.1 Android SDK, Android SDK/NDK r30
(30.0.16248370), and `swiftly`. Toolchain selection is process-local. SDKs and build
outputs can live on the external drive; no global compiler configuration is changed.

From the repository root:

```sh
swift test --package-path XMRadioCore --jobs 2
bash scripts/test-radio-core-android.sh --serial emulator-5560
bash scripts/build-android.sh --no-daemon
```

The core harness accepts an explicitly selected ARM64 emulator, copies native test
libraries into its own temporary directory, and removes that directory afterward.
It does not install/uninstall apps or modify account data. It explicitly selects
Swift Testing; the generated runner defaults to XCTest, which would run zero tests.
Fourteen tests (fifteen cases including both regions) passed on macOS and Android on
October 20, 2026. These fixture tests validate request structure, malformed/error
responses, channel deduplication/order, missing artwork, and artwork URL filtering.
They also check authentication → session establishment → channel discovery, failed-session gating,
and key validation. They do not establish successful live sign-in or streaming.

Native routing, AES reads, and encrypted storage checks:

```sh
bash scripts/test-radio-native-android.sh --serial emulator-5560
```

This installs matching debug app/test APKs and runs 22 offline instrumentation
checks, including controller identity, metadata isolation and bounded artwork.
The storage fixture uses its own preferences and preserves the real
account session. Live playback and session-import tests require explicit opt-in
arguments, so ordinary test runs do not play account media or import credentials.

An explicitly supplied XMRadioCore session snapshot can be migrated with:

```sh
python3 scripts/import-radio-session-android.py --serial emulator-5560 --file /private/path/session.json
```

The script sends the snapshot through standard input into the app's private storage,
encrypts it using the test-only importer, removes the temporary device copy, and opens
the app for provider validation. It never passes cookie values in command arguments
or prints them. The real iPhone cookie migration succeeded without a password; its
temporary local copies were removed after validation. Subsequent app updates and
cold launches restored the refreshed encrypted session without authentication.

The debug APK is written to `../build/android/XMWatchAndroid-debug.apk`. Android
builds currently target ARM64 only. Dated release checkpoints below record their
packaging and runtime verification scope.

The first debug APK built and launched successfully on the ARM64 API 37 emulator
(`emulator-5560`) on October 20, 2026. The sign-in screen was inspected in the UI
hierarchy and screenshot. Evidence is under `../build/android/evidence/`. This launch
check does not exercise authenticated channel browsing or favorites persistence.

The first live sign-in attempt reported an unexpected response. Comparison with the
Apple implementation identified a missing `/resume` session request between login
and Discovery. The Android client now performs that step using the same cookie
session, validates its playback key material, and identifies failures by request
stage. Diagnostics contain only the stage, HTTP status, response size, envelope
presence, module count, and numeric provider codes. Credentials, cookies, response
bodies, and session keys are never included. A subsequent live attempt confirmed successful login and session setup (code 100),
then channel discovery returned code 208. The client now explicitly carries
in-memory cookies with domain/path/expiry/secure scoping, disables the automatic
cookie jar, and reports numeric provider failures separately from malformed JSON.
The real URLSession fixture test exercises cookie rotation across all three requests
on both macOS and Android. The next live attempt succeeded: login, session setup, and channel discovery all
returned HTTP 200/code 100. The user confirmed entry into the app, and the emulator
UI showed real channels. Evidence: `../build/android/evidence/cookie-fix/`.

If channel loading fails after session setup, the screen offers **Retry Loading
Channels** using the same in-memory session. It does not retain the password or
retry authentication automatically. Diagnostic requests report only whether a
Cookie header is present and the number of stored cookies.

## Initial playback milestone

On October 20, 2026, 14 shared Swift tests passed on both macOS and Android,
three native Android fixture checks passed, and the opt-in live check passed:

```sh
python3 scripts/test-radio-live-android.py --serial emulator-5560
```

Run the native harness first to install matching debug app/test APKs. The live
check requires an already authorized encrypted session. It briefly plays live radio,
checks background decoding and the foreground service, pauses/resumes through the
app's own framework media-session token, switches channels through the app UI, and
stops playback afterward. It never adopts shell permissions in the app. It uses
coordinates from the actual UI hierarchy for the dedicated emulator; source URIs,
cookies and keys are not printed. On failure it stops its target app, preserving data.

The ten-second background sample advanced 433 decoded buffers. Its window-relative
position moved only 0.239 seconds because live HLS windows rebase as segments expire;
decoded output is the reliable progression assertion. Media3-facing URIs remained
opaque. Evidence and frozen APKs: `../build/android/evidence/playback/`.

This work also fixed an empty Now Playing screen: playback state now has a shared
model and the player view observes that model directly. Android controls use supported
symbols or native SwiftUI shapes, avoiding missing-symbol warning icons.

## Metadata, renewal, recovery, and release checks

The metadata parser now handles the provider's zero-duration live cuts, selecting
the current song until a newer cut begins. The Android player uses its audible HLS
timeline, updates both Now Playing and the system media session, and retains channel
metadata during gaps. The core suite has 22 tests passing on macOS and native Android.
Six native fixture checks cover routing, actual AES reads, encrypted storage,
credential/key renewal, Pause invalidating pending renewal work, and next/previous
commands reaching the Swift channel selector without seeking the decoder.

Background maintenance belongs to the shared playback model, independently of view
visibility. It refreshes the live session every 480 seconds and updates the existing
source's private credentials. Versioned opaque key URIs retain old keys for in-flight
playlists. Decoder/network errors and prolonged buffering trigger reconnects with
backoff capped at 30 seconds. Explicit Pause/Stop invalidates pending work; an expired
authentication session stops retries. A reconnecting media service retains its
foreground notification, including a Cancel action. Late snapshot writes cannot
restore credentials after Sign Out.

The short live check has passed song metadata, background decoding, system pause/
resume, an actual broken stream route followed by automatic recovery, and channel
switching. The normal-interval renewal check uses:

```sh
python3 scripts/test-radio-live-android.py --serial emulator-5560 \
  --verify-renewal --verify-recovery --output build/android/evidence/maintenance
```

This waits for the real eight-minute renewal rather than changing the app's clock or
shortening its timer. The recovery step changes only the test stream's in-memory
route, preserving cookies and device networking. The 515.8-second run passed real
eight-minute renewal with an unchanged opaque source URI, continued decoded audio,
automatic recovery, metadata, background playback, system pause/resume, and channel
switching. Results and the tested APK are under `build/android/evidence/maintenance`.

Build the optimized APK and app bundle:

```sh
bash scripts/build-android.sh --release --no-daemon
```

The current candidate is non-debuggable, signed with the development keystore for
local testing, ARM64 only, min SDK 28/target SDK 36. Static verification checked all
31 native libraries and 16 KB ELF/ZIP alignment. The optimized app passed saved-session
restoration using the existing authorized cookies, song metadata, 443,822 output
frames over ten seconds in the background, foreground service, and system pause/
resume. It was installed on the emulator and left paused. Results are under
`build/android/evidence/release`. No store upload was performed.
Optimized runtime checks use the public app UI, Android media controls, and actual
AudioFlinger output frames, without injecting the debug test runtime:

```sh
python3 scripts/test-radio-release-android.py --serial emulator-5560 \
  --apk build/android/release-candidate/XMWatchAndroid-release.apk \
  --output build/android/evidence/release
```

Search and a reversible local favorite passed the UI harness: filtering returned
only matching channels, the Favorites tab updated, and the original local favorite
set was restored. Channel lists read the observable model in their own view body
so navigation content does not retain an old search/favorites snapshot.

Re-run with:

```sh
python3 scripts/test-radio-library-ui-android.py --serial emulator-5560 \
  --output build/android/evidence/library-ui
```


## Android system channel controls and notification routing

The session player advertises next/previous commands for the active radio source.
Those commands request a new authenticated stream through the Swift model and
invalidate older renewal work immediately. The decoder keeps a one-item playlist;
controllers cannot replace it with arbitrary media. System channel changes retain
the currently selected app tab. App channel buttons still open Now Playing.

Both the connecting notification and the Media3 notification open Now Playing via
an immutable activity PendingIntent. The activity handles both cold launches and
new intents on an existing task.

The six native fixture checks and the live controller/recovery check passed. The
system-controls milestone APK passed actual app next/previous buttons, Android system next/
previous, decoded output after every channel change, and a real notification-shade
tap from Channels to Now Playing. It also passed saved-cookie restoration,
metadata, background audio (445,822 frames in ten seconds), foreground service,
and pause/resume; playback was left paused. Evidence and matching APK/AAB are in
`build/android/evidence/system-controls-release`, with the debug live check under
`build/android/evidence/system-controls-final`.

The optimized harness checks screen navigation while the app stays alive. The
instrumentation runner closes its activity at completion, so inspecting that screen
afterward cannot prove where the notification opened.

This historical milestone predates the Android Auto/controller implementation
described below. Real-device/headset verification and Android glasses remain
unfinished; Wear OS is outside the current scope.


## Saved-session retry and resume-last-channel

Startup account restoration now belongs to the playback model, so recreating its
view cannot cancel the operation and strand the app in a busy state. A transient
failure offers **Retry Saved Session**, using the encrypted cookie snapshot with
no username/password request. Successful session establishment saves rotated
cookies before fetching the channel catalog, allowing catalog-only failures to use
**Retry Loading Channels**. An explicitly rejected/expired saved session offers
sign-in instead of retrying indefinitely. Sign Out cancels outstanding operations
and clears both the encrypted session and last-channel selection.

**Settings → Resume Last Channel** is opt-in. It saves the successfully resolved
channel and resumes the live broadcast once after account/catalog restoration.
It does not override a channel the user has already selected. With the setting
off, reopening the app restores the account and stays silent.

The emulator UI check passed enabling the setting, cold-start resumption with
advancing decoded audio, disabling it and cold-starting silently, then denying
networking to XMWatch alone and retrying after restoring connectivity. The retry
loaded channels with zero password-authentication requests and retained encrypted
session storage. It restores the original package firewall policy, firewall-chain
state, resume preference, and last-channel preference afterward.

```sh
python3 scripts/test-radio-session-ui-android.py --serial emulator-5560 \
  --output build/android/evidence/session-ui
```

This opt-in check expects a signed-in **debug** emulator with channel resumption
initially off. It preserves the existing authorized cookies and needs no login.
Evidence is under `build/android/evidence/session-ui`. The optimized-build
regression result is recorded separately under `build/android/evidence/session-release`.


## Channel browsing, appearance, and artwork

Channels now has a category menu combined with search, a clear-filters action, and
channel-logo rows with favorite controls and a current-channel marker. Empty search
results and empty Favorites have explicit messages. Refresh works through the
navigation-bar button or pull-to-refresh; a failed request retains the existing
catalog and shows a retryable error. A successful refresh clears that error.

Settings supports System, Light, and Dark appearance, saved across cold starts.
Channel logos use dark rounded tiles so white logos remain visible in Light mode.
Now Playing reserves its artwork area while images load.

Discovery currently returns HTTP URLs from a legacy art hostname with a mismatched
HTTPS certificate. The core maps known legacy image hosts and `/images/` paths to
SiriusXM's working `https://albumart.siriusxm.com` endpoint. A live image fetch
returned HTTP 200/image/png, and logos were visually verified in both app themes.
Arbitrary HTTP image hosts, credential-bearing URLs, and file URLs are not enabled.
Diagnostics report counts without image URLs or cookie values.

The shared suite passed 22 tests on macOS and ARM64 Android, including the logo
mapping regression. UI checks passed category filtering, combined search, Clear
Filters, failed refresh retaining rows, refresh retry, theme persistence, favorite
toggling, and the empty-favorites view. The full browsing run is frozen under
`build/android/evidence/browsing-ui-final`; the final contrast-only screenshots and
pixel checks are under `build/android/evidence/browsing-contrast`.

```sh
python3 scripts/test-radio-browsing-ui-android.py --serial emulator-5560 \
  --output build/android/evidence/browsing-ui-final
# Appearance-only verification after a visual change:
python3 scripts/test-radio-browsing-ui-android.py --serial emulator-5560 \
  --appearance-only --output build/android/evidence/browsing-contrast
```

The UI harness uses the existing signed-in debug emulator with automatic channel
resumption off. It restores the original appearance preference and package-specific
network policy. It does not replace the encrypted session or request credentials.


The final optimized candidate passed saved-cookie restoration, song metadata,
background audio (445,822 output frames in ten seconds), foreground service,
app/system next/previous, a real notification tap into Now Playing, and pause/
resume. It is installed on the emulator and left paused. Static verification
checked its non-debuggable manifest, all 31 ARM64 native libraries, and 16 KB
ELF/ZIP alignment. The APK/AAB and source/artifact hashes are frozen under
`build/android/evidence/browsing-release`. No store upload was performed.

## Reviewed SkipUI navigation patch

The Android build prepares a checked patch for SkipUI 1.64.0 before compiling.
It corrects delayed navigation cleanup reading an old stack snapshot, which can
remove a newly pushed destination and leave a blank pane under main-thread load.
The implementation follows [upstream issue 572](https://github.com/skiptools/skip-ui/issues/572).

`../scripts/prepare-android-dependencies.py` validates the resolved revision and
the original/patched source hashes before applying the repository's
`patches/skip-ui-1.64.0-navigation-state.patch`. Repeated builds are idempotent.
A different SDK revision or unexpected source change stops preparation so the
patch can be reviewed or retired, rather than silently editing different code.
Use the repository build script when building from a fresh checkout.

This is the shared SDK cleanup correction. Slingshot's separate Swift-owned tab
paths and its activity-recreation tests are specific to that app; this note does
not claim equivalent state-restoration coverage for this app.

The patched optimized APK/AAB and mapping passed package/signature and 16 KB
native-alignment checks. The emulator runtime check passed saved-cookie restoration, real decoded radio audio, background playback, UI/system Next/Previous, system pause/play and actual notification return.
Installed APK bytes matched the recorded artifact. Evidence and immutable artifacts
are under `build/android/evidence/sdk-navigation` and
`build/android/checkpoints/sdk-navigation`. Existing account data was preserved;
no store upload was performed. Core/auth/playback sources did not change, and
their earlier suites remain the baseline rather than being rerun for this SDK patch.

## Swift build preflight

`scripts/build-android.sh` explicitly runs the Swift compiler/transpiler before
Gradle. Slingshot exposed a Gradle-plugin failure mode where a failed Swift
pre-build could still lead to a successful package containing older generated
sources. The shared guard stops before Gradle on that failure. An intentional
compiler-error probe in Slingshot left its existing APK unchanged; the guarded
Cadence, XMWatch and Slingshot debug build paths all passed afterward. The guard
uses the existing macOS/Xcode iPhoneOS SDK setup. This is a build-workflow change;
the prior optimized runtime checkpoints remain the app-behavior evidence.

## Session-save rollback

XMWatch uses the session-vault correction first verified in Slingshot. Vault save,
load and clear operations are serialized. If replacing the encrypted preferences
returns failure or throws, the previous IV/ciphertext are restored before readers
can use the replacement. Android preferences can expose changed values in memory
even when a disk commit reports failure. The new native fixture reproduced that
behavior before the fix and now checks both false-return and throwing outcomes.
It uses separate test-owned preferences and never replaces the real saved cookie.

```sh
bash scripts/test-radio-native-android.sh --serial emulator-5560
python3 scripts/test-radio-session-ui-android.py --serial emulator-5560 --output build/android/evidence/vault-session-ui
bash scripts/build-android.sh --release --no-daemon
python3 scripts/test-radio-release-android.py --serial emulator-5560 --apk build/android/XMWatchAndroid-release.apk --output build/android/evidence/vault-release
```

The native suite now has seven tests. The failure fixture controls commit outcomes;
it does not establish behavior under real disk exhaustion. Cookie expiration still
requires the provider's normal reauthorization. Cadence's browser session uses
Android WebView CookieManager rather than this preferences-based vault, so this
change applies to Slingshot and XMWatch. Apple app sources are unaffected.

The session-rollback checkpoint passed seven native fixtures, saved-cookie UI retry
and last-channel restoration, and optimized live radio playback with metadata,
background audio, app/system channel controls, pause/resume and notification return.
The existing cookie was preserved; no password authentication was requested. The
release was left paused on the emulator. Artifacts, source hashes and before/after
fixture evidence are under `build/android/checkpoints/session-rollback`, with the
latest aggregate in `build/android/evidence/verification.json`. Earlier long-renewal
and core tests remain historical evidence; core/auth/player sources did not change.

## Android Auto and external radio controllers (October 22, 2026)

The media-library service now advertises Android Auto support and modern/legacy
browser intents. Controllers can browse All Channels, Favorites and Categories,
follow More folders through the full catalog, search channel names/numbers/categories,
select by voice, change channels and resume the saved channel after process death.
Startup restores the existing encrypted cookie. Opening a browser does not trigger
the phone's optional last-channel autoplay or open an Activity. Metadata-only
resumption does not prepare audio; an explicit Play resumes the live broadcast.

Controller selections use app-owned channel records. Supplied media URLs,
display metadata and extras do not become decoder sources. Preparation stays
paused until Play, and Pause/Stop/new selections invalidate pending work. The
service and image provider use the installed-package/UID/release-certificate
policy shared with Cadence and Slingshot. Unknown IDs and unapproved clients fail.

Browse and current-song artwork use opaque local content URIs. Covers are loaded
on demand from the catalog, checked against the current account and converted to
JPEGs capped at 512 pixels / 256 KiB. The provider cache holds at most 64 images /
8 MiB; cached originals are limited to 64 files / 16 MiB. Neither provider cookies,
stream tokens nor private filesystem paths enter controller metadata. Catalog
refreshes update stored records while retaining their existing IDs.

```sh
python3 scripts/test-radio-controller-android.py --serial emulator-5554 --allow-live-radio
```

This explicit live harness builds and installs matching app/test/probe APKs and
reuses the signed-in cookie. `--skip-build` reuses current artifacts. It passed
**22 native fixtures**, a cold browse/playback check of all **459 channels**, and
separate cold playback resumption. The live checks decoded covers in both browser
and playback metadata, decoded radio audio, exercised search/voice/pause/next,
rejected injected sources and cancelled/unknown selections, and launched no phone
Activity. An independent platform-only browser checked legacy discovery, both
approved and rejected connections, cover access, silent preparation and playback
controls. The existing phone playback regression also passed.

Evidence is under `build/android/evidence/controller-library/`. The new optimized
APK/AAB and R8 mapping are under `build/android/controller-release/`; earlier
checkpoints remain preserved. Native fixtures and modern controller/cold-resumption
checks are scoped to the debug build; optimized phone and independent-controller
results are recorded separately. Physical Android Auto/head units, real-device
headsets, dynamic updates to an already-open external browser and Android glasses
remain follow-up work. Wear OS is outside the current scope.

The optimized APK additionally passed the existing phone check with real decoded
audio, 445,822 background frames over ten seconds, app/system channel changes,
pause/resume and an actual notification tap into Now Playing. The notification
harness identifies XMWatch's media card by app identity so changing song metadata
does not invalidate its target. The independent controller check also passed on
that same optimized APK, with no test runtime injected into the app.

`build/android/checkpoints/controller-library-20261022/` preserves both builds,
the test APK, AAB, R8 mapping, logs and production-input hashes. The installed
optimized APK SHA-256 is
`e1092e9b288e7aec8827560d1a9c1c90e6161a005b1744666f5ddfb8ce798159`.
`milestone-verification.json` records the exact debug and release scopes.


### Connected browser catalog updates

Favorites changes and refreshed channel catalogs now notify already-connected
Media3 browsers. Subscribed folder counts are recomputed through the existing
Swift catalog, and active search queries receive refreshed result counts. Changes
are coalesced; superseded callbacks, unsubscribed folders and disconnected
controllers cannot receive late results. Signing out clears exposed catalog data.

Validation on `CadenceCarLibrary` (`emulator-5560`): 22 native tests and one real
saved-cookie browser/UI integration test passed. One browser stayed connected
while the phone toggled and restored a local favorite; both counts arrived, an
unsubscribe stopped later notifications, and no radio playback started. The
harness restored the exact encrypted cookie and preferences captured before the
run and removed its private escrow.

```sh
bash scripts/test-radio-catalog-updates-android.sh --serial emulator-5560
```

The preservation driver checks the AVD name, defaulting to `CadenceCarLibrary`.
Use `RADIO_TEST_AVD=<name>` only for an intentional alternate AVD. Port 5554 was
found to belong to the concurrent `OpenEMRNative37` emulator; the original radio
cookie remained present in CadenceCarLibrary. Evidence is under
`build/android/evidence/catalog-updates/`. This is debug emulator validation;
physical head-unit refresh, the full search/account lifecycle matrix and optimized
runtime remain unverified. Region switching while signed in is still unfinished:
XMRadioCore deliberately rejects restoring a cookie snapshot in a different
region, so the working cookie is not silently reused against another region.


### Switching regions with saved sessions

Settings now offers a region picker while signed in; the sign-in page uses the
same switching behavior. Switching first snapshots the current session, then
loads only a matching encrypted regional session. With no saved session for the
target region, the app shows sign-in. Favorites and last-channel preferences are
kept separately per region, and playback/preparation is cancelled on the switch.
Returning to a saved region restores its cookie without entering credentials.
Sign Out clears the active region's session/cache without clearing another region.
Invalid or moved cross-region cookie snapshots cannot replace the active account.

The debug build passed 25 native tests and a saved-cookie US → unsigned Canada →
US UI roundtrip on CadenceCarLibrary. The US cookie did not become Canada's active
cookie, the US account/favorites returned, and no playback or credential entry
occurred. The harness restored all 12 active/regional session and defaults file
paths to their original presence/bytes afterward:

```sh
bash scripts/test-radio-regions-android.sh --serial emulator-5560
```

Evidence: `build/android/evidence/regions/`; checkpoint:
`build/android/checkpoints/regions-20261022/`. This supersedes the earlier note
that signed-in region switching was unfinished. Actual Canadian account sign-in,
Canadian playback, physical devices, and optimized runtime remain unverified.

## Saved phone checkpoint — October 22, 2026

Radio phone checkpoint. Source, repeatable build scripts and harnesses are committed together.
Artifact hashes and the exact verification limits are recorded in [CHECKPOINT.json](CHECKPOINT.json).

- Optimized APK/AAB build and static package verification passed.
- Saved-session live release radio playback, background decoding, metadata, app/system channel changes and pause/resume passed.
- Actual release Settings diagnostics off/on persistence across cold starts passed.
- Apple sign-in views type-checked against simulator SwiftUI SDKs using a provider stub.

Remaining work:

- Canadian-account authentication/playback and physical Android accessories remain unverified.
- Apple auth view checking does not constitute a full Apple project build or live authentication.
