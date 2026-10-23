#!/usr/bin/env python3
"""Run real foreground tune/pause/resume using the existing encrypted cookie."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
PACKAGE = 'com.doctordurant.xmwatch.android'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--internal', action='store_true')
    parser.add_argument('--output', type=Path, default=REPO/'build/android/evidence/phone-automation-live')
    args = parser.parse_args()
    if args.serial != 'emulator-5560':
        parser.error('Use CadenceCarLibrary emulator-5560.')
    args.output.mkdir(parents=True, exist_ok=True)
    adb = [str(Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))/'platform-tools/adb'), '-s', args.serial]

    def run(*command):
        return subprocess.run(adb+list(command), capture_output=True, text=True, check=True, timeout=30).stdout.strip()

    def installed(package):
        paths = run('shell', 'pm', 'path', package).splitlines()
        assert len(paths) == 1 and paths[0].startswith('package:')
        return run('shell', 'sha256sum', paths[0][8:]).split()[0]

    expected_app = json.loads((REPO/'build/android/checkpoints/phone-automation-20261022/manifest.json').read_text())['verification']['debugAPK_SHA256']
    assert installed(PACKAGE) == expected_app, 'Unexpected app: rebuild/freeze deliberately before running.'
    if not args.internal:
        (args.output/'verification.json').unlink(missing_ok=True)
        test_apk = REPO/'xmwatch-android/.build/Android/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
        tested = args.output/'tested'
        tested.mkdir(exist_ok=True)
        (tested/'XMWatchAndroid-tests.apk').write_bytes(test_apk.read_bytes())
        subprocess.run([sys.executable, str(REPO/'scripts/run-radio-preserving-state.py'), '--serial', args.serial,
                        '--output', str(args.output/'state-restoration.json'), '--', sys.executable, str(Path(__file__).resolve()),
                        '--serial', args.serial, '--output', str(args.output), '--internal'], check=True)
        restored = json.loads((args.output/'state-restoration.json').read_text())
        assert restored['privateFilePresenceAndBytesRestored'] and restored['privateBackupEscrowRemoved']
        result = json.loads((args.output/'playback-result.json').read_text())
        assert installed(PACKAGE) == expected_app
        test_hash = hashlib.sha256((tested/'XMWatchAndroid-tests.apk').read_bytes()).hexdigest()
        assert installed(PACKAGE+'.test') == test_hash
        result.update(passed=True, privateStateRestored=True, debugAPK_SHA256=expected_app, testAPK_SHA256=test_hash,
                      physicalDeviceTested=False, optimizedBuildTested=False)
        (args.output/'verification.json').write_text(json.dumps(result, indent=2)+'\n')
        print('Passed: actual radio tune/pause/resume decoded audio with the saved session; private state restored.')
        return
    run('shell', 'am', 'force-stop', PACKAGE)
    run('install', '-r', str(args.output/'tested/XMWatchAndroid-tests.apk'))
    test_hash = hashlib.sha256((args.output/'tested/XMWatchAndroid-tests.apk').read_bytes()).hexdigest()
    assert installed(PACKAGE+'.test') == test_hash and installed(PACKAGE) == expected_app
    command = adb+['shell', 'am', 'instrument', '-w', '-r', '-e', 'allowLivePhoneAutomation', 'true', '-e', 'class',
                   'xmwatch.android.PhoneAutomationLiveTest', PACKAGE+'.test/androidx.test.runner.AndroidJUnitRunner']
    with (args.output/'instrumentation.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
    log = (args.output/'instrumentation.log').read_text()
    assert 'OK (1 test)' in log and not any(marker in log for marker in ['FAILURES', 'Process crashed', 'INSTRUMENTATION_STATUS_CODE: -3'])
    rows = [json.loads(line.split('phoneAutomationLiveResult=', 1)[1]) for line in log.splitlines() if 'phoneAutomationLiveResult=' in line]
    assert len(rows) == 1
    result = rows[0]
    assert all(result.get(key) is True for key in ['savedSessionUsed', 'actualTuneAction', 'decodedAudio', 'pauseResumeActions', 'samePlayerChannelAndSession', 'leftPaused'])
    (args.output/'playback-result.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
