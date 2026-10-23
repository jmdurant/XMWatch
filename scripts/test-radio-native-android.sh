#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != --serial || ! "${2:-}" =~ ^emulator-[0-9]+$ ]]; then
    echo 'Usage: bash scripts/test-radio-native-android.sh --serial emulator-5560 [--skip-build]' >&2
    exit 2
fi
serial="$2"
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
adb="$ANDROID_HOME/platform-tools/adb"
[[ "$("$adb" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')" == arm64-v8a ]] || exit 1
if [[ "${3:-}" != --skip-build ]]; then
    bash "$repo/scripts/build-android.sh" --no-daemon :app:assembleDebugAndroidTest
fi
apk="$repo/build/android/XMWatchAndroid-debug.apk"
test_apk="$repo/xmwatch-android/.build/Android/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
mkdir -p "$repo/build/android/evidence"
"$adb" -s "$serial" install -r "$apk"
"$adb" -s "$serial" install -r "$test_apk"
log="$repo/build/android/evidence/native-tests.log"
"$adb" -s "$serial" shell am instrument -w -e class xmwatch.android.RadioRegionSessionTest,xmwatch.android.RadioNativeTest,xmwatch.android.ControllerAccessPolicyTest,xmwatch.android.MediaLibraryCatalogTest,xmwatch.android.ControllerArtworkTest \
    com.doctordurant.xmwatch.android.test/androidx.test.runner.AndroidJUnitRunner 2>&1 | tee "$log"
grep -Eq 'OK \([1-9][0-9]* tests?\)' "$log" || { echo 'Native instrumentation did not pass.' >&2; exit 1; }
