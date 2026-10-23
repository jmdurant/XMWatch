#!/bin/bash
# Real DAT 1.0.1 MockDeviceKit: session, WebView renderer and SDK button input.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
adb="$ANDROID_HOME/platform-tools/adb"
serial=""
skip_build=false
internal=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --serial) serial="${2:?Supply the CadenceCarLibrary emulator serial}"; shift 2 ;;
        --skip-build) skip_build=true; shift ;;
        --run-checks-internal) internal=true; shift ;;
        *) echo 'Usage: bash scripts/test-android-meta-glasses.sh --serial emulator-5560 [--skip-build]' >&2; exit 2 ;;
    esac
done
[[ "$serial" =~ ^emulator-[0-9]+$ ]] || { echo 'Select the CadenceCarLibrary emulator explicitly.' >&2; exit 2; }
expected_avd="${RADIO_TEST_AVD:-CadenceCarLibrary}"
[[ "$("$adb" -s "$serial" emu avd name | head -1 | tr -d '\r')" == "$expected_avd" ]] || {
    echo 'This harness requires the dedicated CadenceCarLibrary AVD.' >&2; exit 2;
}
output="${XMWATCH_META_GLASSES_OUTPUT:-$repo/build/android/evidence/meta-glasses}"
mkdir -p "$output"
package=com.doctordurant.xmwatch.android
if [[ "$internal" == false ]]; then
    rm -f "$output/verification.json"
    if [[ "$skip_build" == false ]]; then
        bash "$repo/scripts/build-android.sh" --max-workers=2 :app:assembleDebugAndroidTest > "$output/android-build.log" 2>&1
    fi
    apk="$repo/build/android/XMWatchAndroid-debug.apk"
    tests="$repo/xmwatch-android/.build/Android/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
    test -f "$apk" && test -f "$tests"
    "$adb" -s "$serial" shell run-as "$package" id > "$output/debug-install-precondition.log"
    "$adb" -s "$serial" install -r "$apk" > "$output/install-app.log"
    "$adb" -s "$serial" install -r "$tests" > "$output/install-tests.log"
    python3 "$repo/scripts/run-radio-preserving-state.py" --serial "$serial" --output "$output/state-restoration.json" -- \
        bash "$0" --serial "$serial" --run-checks-internal
    python3 - "$output" "$apk" "$serial" <<'PY'
import hashlib,json,os,pathlib,subprocess,sys
out,apk,serial=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
restored=json.loads((out/'state-restoration.json').read_text())
assert restored['privateFilePresenceAndBytesRestored'] and restored['privateBackupEscrowRemoved']
def adb(*args): return subprocess.run([str(pathlib.Path(os.environ['ANDROID_HOME'])/'platform-tools/adb'),'-s',serial,*args],check=True,capture_output=True,text=True,timeout=30).stdout.strip()
digest=hashlib.sha256(apk.read_bytes()).hexdigest()
installed=adb('shell','pm','path','com.doctordurant.xmwatch.android').removeprefix('package:')
assert adb('shell','sha256sum',installed).split()[0]==digest
(out/'verification.json').write_text(json.dumps({'passed':True,'avd':os.environ.get('RADIO_TEST_AVD','CadenceCarLibrary'),'serial':serial,
    'debugAPK_SHA256':digest,'realSDKMockChecks':4,'radioBindingChecks':1,'sdkVersion':'1.0.1','privateStateRestored':True,
    'physicalGlassesTested':False,'metaAIAccountUsed':False,'optimizedBuildTested':False},indent=2)+'\n')
PY
    echo 'Passed: 4 real DAT SDK mock checks and 1 radio binding check; private state restored.'
    exit
fi
# Grant only the Nearby devices runtime permission required by SDK initialization,
# then restore its previous state independently of private preference restoration.
had_permission=false
permission_state="$("$adb" -s "$serial" shell dumpsys package "$package")"
if rg -q 'android.permission.BLUETOOTH_CONNECT: granted=true' <<< "$permission_state"; then had_permission=true; fi
cleanup() {
    "$adb" -s "$serial" shell am force-stop "$package" >/dev/null 2>&1 || true
    if [[ "$had_permission" == false ]]; then "$adb" -s "$serial" shell pm revoke "$package" android.permission.BLUETOOTH_CONNECT >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
"$adb" -s "$serial" shell pm grant "$package" android.permission.BLUETOOTH_CONNECT
"$adb" -s "$serial" shell am force-stop "$package"
"$adb" -s "$serial" shell am instrument -w -r -e class xmwatch.android.MetaGlassesDisplayTest,xmwatch.android.MetaRadioPlaybackBindingTest \
    -e allowMetaGlassesFixture true "$package.test/androidx.test.runner.AndroidJUnitRunner" > "$output/native-tests.log" 2>&1
python3 - "$output/native-tests.log" <<'PY'
import pathlib,sys
log=pathlib.Path(sys.argv[1]).read_text()
assert 'OK (5 tests)' in log and log.count('INSTRUMENTATION_STATUS_CODE: 0\n') == 5, 'Inspect '+sys.argv[1]
assert all(x not in log for x in ['FAILURES','Process crashed','INSTRUMENTATION_STATUS_CODE: -4'])
PY
