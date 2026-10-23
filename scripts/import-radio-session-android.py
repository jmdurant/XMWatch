#!/usr/bin/env python3
"""Migrate an explicitly supplied cookie snapshot into the debug app's vault.

No password is needed. The snapshot stays out of command-line arguments and logs.
The app-private temporary copy is removed after the instrumentation import.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--file', required=True, type=Path)
args = parser.parse_args()
if not re.fullmatch(r'emulator-[0-9]+', args.serial):
    parser.error('Choose an explicitly selected Android emulator.')
raw = args.file.read_bytes()
if not 0 < len(raw) <= 131072:
    parser.error('Snapshot must be at most 128 KiB.')
snapshot = json.loads(raw)
if snapshot.get('version') != 1 or snapshot.get('region') not in ['US', 'CA'] or not snapshot.get('cookies'):
    parser.error('Expected an XMRadioCore version 1 cookie snapshot.')
sdk = Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))
adb = [str(sdk / 'platform-tools/adb'), '-s', args.serial]
package = 'com.doctordurant.xmwatch.android'
def run(*command, **kwargs):
    return subprocess.run(adb + list(command), check=True, capture_output=True, **kwargs)
run('shell', 'am', 'force-stop', package)
run('shell', 'run-as', package, 'mkdir', '-p', 'files')
try:
    run('shell', '-T', 'run-as', package, 'dd', 'of=files/session-import.json', input=raw)
    run('shell', 'run-as', package, 'chmod', '600', 'files/session-import.json')
    result = run('shell', 'am', 'instrument', '-w', '-e', 'allowSessionImport', 'true', '-e', 'class', 'xmwatch.android.RadioSessionImportTest',
                 package + '.test/androidx.test.runner.AndroidJUnitRunner').stdout.decode()
    if 'OK (1 test)' not in result:
        raise RuntimeError('Session import failed; no credential data was printed.')
finally:
    run('shell', 'run-as', package, 'rm', '-f', 'files/session-import.json')
run('shell', 'am', 'start', '-W', '-n', package + '/xmwatch.android.MainActivity')
print('Existing cookie snapshot encrypted and imported; app opened for provider validation.')
