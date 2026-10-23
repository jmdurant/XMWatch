#!/usr/bin/env python3
"""Opt-in controller check using the emulator's existing encrypted radio cookie."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ADB = '/opt/homebrew/share/android-commandlinetools/platform-tools/adb'
PACKAGE = 'com.doctordurant.xmwatch.android'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--allow-live-radio', action='store_true', required=True)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT/'build/android/evidence/controller-library')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.serial): parser.error('Select an emulator explicitly')
    out = args.output; out.mkdir(parents=True, exist_ok=True)
    def adb(*values):
        return subprocess.run([ADB, '-s', args.serial, *values], capture_output=True, text=True, check=True, timeout=180).stdout
    if adb('shell', 'getprop', 'ro.product.cpu.abi').strip() != 'arm64-v8a': parser.error('Use an ARM64 emulator')
    if not args.skip_build:
        for name, command in [('build', ['bash', 'scripts/build-android.sh', '--no-daemon', ':app:assembleDebugAndroidTest']),
                              ('probe-build', ['bash', 'scripts/build-android-controller-probe.sh'])]:
            with (out/(name+'.log')).open('w') as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    apk = ROOT/'build/android/XMWatchAndroid-debug.apk'
    tests = ROOT/'xmwatch-android/.build/Android/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
    probe = ROOT/'scripts/android-controller-probe/app/build/outputs/apk/debug/app-debug.apk'
    for path in [apk, tests, probe]: adb('install', '-r', str(path))
    checks = [
        ('native-run', 'xmwatch.android.RadioNativeTest,xmwatch.android.ControllerAccessPolicyTest,xmwatch.android.MediaLibraryCatalogTest,xmwatch.android.ControllerArtworkTest', 22, []),
        ('live-controller', 'xmwatch.android.RadioControllerLiveTest#coldCookieBrowseSearchPrivatePreparationAndLiveRadioControls', 1, ['-e', 'allowLiveRadioController', 'true']),
        ('cold-resumption', 'xmwatch.android.RadioControllerLiveTest#coldExplicitPlaybackResumptionUsesTheSavedCookieAndChannel', 1, ['-e', 'allowLiveRadioController', 'true']),
    ]
    for name, classes, count, extra in checks:
        adb('shell', 'am', 'force-stop', PACKAGE)
        log = adb('shell', 'am', 'instrument', '-w', '-e', 'class', classes, *extra, PACKAGE+'.test/androidx.test.runner.AndroidJUnitRunner')
        (out/(name+'.log')).write_text(log)
        expected = 'OK ({} {})'.format(count, 'test' if count==1 else 'tests')
        if expected not in log or 'FAILURES' in log: raise RuntimeError('Failed '+name+'; inspect its log')
        print('Passed:', name, flush=True)
    adb('shell', 'am', 'force-stop', PACKAGE)
    log = adb('shell', 'am', 'instrument', '-w', '-e', 'allowOwnedControllerProbe', 'true', '-e', 'requireArtwork', 'true',
              'com.doctordurant.xmwatch.controllerprobe/xmwatch.testing.RadioLibraryProbe')
    (out/'external-controller-debug.log').write_text(log)
    for flag in ['status=passed', 'controllerArtworkDecoded=true', 'unapprovedBrowserRejected=true', 'unapprovedArtworkCallerRejected=true', 'playPauseNextStopAndVoiceSearch=true']:
        if flag not in log: raise RuntimeError('External controller failed: '+flag)
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    installed = adb('shell', 'pm', 'path', PACKAGE).strip().removeprefix('package:')
    assert adb('shell', 'sha256sum', installed).split()[0] == digest
    result = {'passed': True, 'apkSHA256': digest, 'nativeTests': 22, 'cookieOnlyColdBrowseAndPlayback': True,
              'coldExplicitResumption': True, 'independentLegacyController': True, 'unapprovedCallersRejected': True,
              'physicalAndroidAutoTested': False, 'scope': 'debug ARM64 emulator; uses existing cookie; live radio left stopped'}
    (out/'verification.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Radio controller browsing, artwork, playback, voice and cold resumption passed.')

if __name__ == '__main__': main()
