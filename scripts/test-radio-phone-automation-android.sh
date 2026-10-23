#!/bin/bash
# Actual cold/warm phone automation, launcher shortcuts and owned inert playback.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
serial=""
internal=false
skip_build=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --serial) serial="${2:?Supply emulator-5560}"; shift 2 ;;
        --skip-build) skip_build=true; shift ;;
        --internal) internal=true; shift ;;
        *) echo 'Usage: bash scripts/test-radio-phone-automation-android.sh --serial emulator-5560 --skip-build' >&2; exit 2 ;;
    esac
done
[[ "$serial" == emulator-5560 ]] || { echo 'Use the dedicated CadenceCarLibrary emulator-5560.' >&2; exit 2; }
[[ "$(adb -s "$serial" emu avd name | head -1 | tr -d '\r')" == CadenceCarLibrary ]] || exit 2
output="${RADIO_PHONE_AUTOMATION_OUTPUT:-$repo/build/android/evidence/phone-automation}"
mkdir -p "$output"
package=com.doctordurant.xmwatch.android
app="$output/tested/XMWatchAndroid-debug.apk"
tests="$output/tested/XMWatchAndroid-tests.apk"
if [[ "$internal" == false ]]; then
    [[ "$skip_build" == true ]] || { echo 'Build the app and tests first, then pass --skip-build.' >&2; exit 2; }
    rm -f "$output/verification.json"
    mkdir -p "$output/tested"
    cp "$repo/build/android/XMWatchAndroid-debug.apk" "$app"
    cp "$repo/xmwatch-android/.build/Android/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk" "$tests"
    RADIO_TEST_AVD=CadenceCarLibrary python3 "$repo/scripts/run-radio-preserving-state.py" --serial "$serial" \
        --output "$output/private-state-restoration.json" -- bash "$0" --serial "$serial" --internal
    python3 - "$output" "$serial" <<'PY'
import hashlib,json,pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1]);restored=json.loads((out/'private-state-restoration.json').read_text())
assert restored['privateFilePresenceAndBytesRestored'] and restored['privateBackupEscrowRemoved']
result=json.loads((out/'ui-result.json').read_text())
for filename,package,key in [('XMWatchAndroid-debug.apk','com.doctordurant.xmwatch.android','debugAPK_SHA256'),
                             ('XMWatchAndroid-tests.apk','com.doctordurant.xmwatch.android.test','testAPK_SHA256')]:
    expected=hashlib.sha256((out/'tested'/filename).read_bytes()).hexdigest()
    def adb(*args):return subprocess.run(['adb','-s',sys.argv[2],*args],check=True,capture_output=True,text=True,timeout=30).stdout.strip()
    paths=adb('shell','pm','path',package).splitlines()
    assert len(paths)==1 and paths[0].startswith('package:')
    assert adb('shell','sha256sum',paths[0][8:]).split()[0]==expected
    result[key]=expected
result.update(passed=True,serial=sys.argv[2],avd='CadenceCarLibrary',phoneAutomationIntegrationChecks=1,focusedParserChecks=3,
              privateStateRestored=True,installedAppAndTestHashesMatched=True,physicalDeviceTested=False)
(out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
PY
    echo 'Passed: actual phone automation and owned playback integration; private state restored.'
    exit
fi
adb -s "$serial" install -r "$app" > "$output/install-app.log"
adb -s "$serial" install -r "$tests" > "$output/install-tests.log"
python3 - "$output" "$serial" <<'PYINSTALLED'
import hashlib,json,pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1]);result={}
for filename,package,key in [('XMWatchAndroid-debug.apk','com.doctordurant.xmwatch.android','debugAPK_SHA256'),('XMWatchAndroid-tests.apk','com.doctordurant.xmwatch.android.test','testAPK_SHA256')]:
    expected=hashlib.sha256((out/'tested'/filename).read_bytes()).hexdigest()
    def adb(*args):return subprocess.run(['adb','-s',sys.argv[2],*args],check=True,capture_output=True,text=True,timeout=30).stdout.strip()
    paths=adb('shell','pm','path',package).splitlines()
    assert len(paths)==1 and paths[0].startswith('package:')
    assert adb('shell','sha256sum',paths[0][8:]).split()[0]==expected
    result[key]=expected
(out/'installed-apk-sha256.json').write_text(json.dumps(result,indent=2)+'\n')
PYINSTALLED
adb -s "$serial" shell am force-stop "$package"
# The original XML and all AtomicFile variants are protected by the outer escrow.
# Disable the existing optional auto-resume before the app process can be created.
python3 - "$serial" <<'PY'
import subprocess,sys,xml.etree.ElementTree as ET
prefix=['adb','-s',sys.argv[1],'shell','run-as','com.doctordurant.xmwatch.android']
def run(*args,**kwargs):return subprocess.run(prefix+list(args),check=True,capture_output=True,timeout=30,**kwargs)
path='shared_prefs/defaults.xml'
present=subprocess.run(prefix+['test','-f',path],capture_output=True,timeout=30)
assert present.returncode in (0,1) and not present.stdout and not present.stderr
root=ET.fromstring(run('cat',path).stdout) if present.returncode==0 else ET.Element('map')
assert root.tag=='map'
key='xm.android.resumeLastChannel'
for node in list(root):
    if node.get('name')==key:root.remove(node)
ET.SubElement(root,'boolean',{'name':key,'value':'false'})
run('mkdir','-p','shared_prefs');run('rm','-f',path+'.bak',path+'.new')
run('dd','of='+path,input=ET.tostring(root,encoding='utf-8',xml_declaration=True))
matches=[node for node in ET.fromstring(run('cat',path).stdout) if node.get('name')==key]
assert len(matches)==1 and matches[0].tag=='boolean' and matches[0].get('value')=='false'
PY
# Original encrypted account and region cache variants are protected by escrow.
adb -s "$serial" shell run-as "$package" rm -f shared_prefs/radio-session.xml shared_prefs/radio-session.xml.bak shared_prefs/radio-session.xml.new shared_prefs/radio-region-US.xml shared_prefs/radio-region-US.xml.bak shared_prefs/radio-region-US.xml.new shared_prefs/radio-region-CA.xml shared_prefs/radio-region-CA.xml.bak shared_prefs/radio-region-CA.xml.new
adb -s "$serial" shell am instrument -w -r -e allowPhoneAutomationFixture true \
    -e class xmwatch.android.PhoneAutomationIntentTest,xmwatch.android.PhoneAutomationIntegrationTest "$package.test/androidx.test.runner.AndroidJUnitRunner" > "$output/instrumentation.log" 2>&1
python3 - "$output" <<'PYRESULT'
import json,pathlib,sys
out=pathlib.Path(sys.argv[1]);log=(out/'instrumentation.log').read_text()
assert 'OK (4 tests)' in log and all(marker not in log for marker in ['FAILURES','Process crashed','INSTRUMENTATION_STATUS_CODE: -4'])
rows=[json.loads(line.split('phoneAutomationUIResult=',1)[1]) for line in log.splitlines() if 'phoneAutomationUIResult=' in line]
assert len(rows)==1
result=rows[0]
assert all(result.get(key) is True for key in ['coldActivityIntent','warmActivityIntent','publishedLauncherShortcuts',
            'entitySelectionUI','intentConsumedAcrossRecreation','invalidInputNoAutoplay','ownedTransportReuse'])
assert result.get('originalAccountUsed') is False and result.get('externalPlaybackStarted') is False
assert result.get('entityPlayAndShuffleRuntimeTested') is False
(out/'ui-result.json').write_text(json.dumps(result,indent=2)+'\n')
PYRESULT
