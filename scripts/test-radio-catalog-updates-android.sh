#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != --serial || ! "${2:-}" =~ ^emulator-[0-9]+$ ]]; then
    echo 'Usage: bash scripts/test-radio-catalog-updates-android.sh --serial emulator-5554 [--skip-build]' >&2
    exit 2
fi
serial="$2"
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
adb="$ANDROID_HOME/platform-tools/adb"
evidence="$repo/build/android/evidence/catalog-updates"
mkdir -p "$evidence"
if [[ "${3:-}" != --skip-build && "${3:-}" != --internal ]]; then
    bash "$repo/scripts/build-android.sh" --no-daemon :app:assembleDebugAndroidTest
fi
if [[ "${3:-}" != --internal ]]; then
    exec python3 "$repo/scripts/run-radio-preserving-state.py" --serial "$serial" \
        --output "$evidence/private-state-restoration.json" -- \
        bash "$repo/scripts/test-radio-catalog-updates-android.sh" --serial "$serial" --internal
fi
bash "$repo/scripts/test-radio-native-android.sh" --serial "$serial" --skip-build > "$evidence/native-run.log" 2>&1
"$adb" -s "$serial" shell am force-stop com.doctordurant.xmwatch.android
"$adb" -s "$serial" shell am instrument -w -e allowCatalogUpdates true -e class xmwatch.android.RadioCatalogUpdatesLiveTest \
    com.doctordurant.xmwatch.android.test/androidx.test.runner.AndroidJUnitRunner 2>&1 | tee "$evidence/instrumentation.log"
grep -Eq 'OK \(1 test\)' "$evidence/instrumentation.log"
grep -q 'catalogUpdatesResult=' "$evidence/instrumentation.log"
