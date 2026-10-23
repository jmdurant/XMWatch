#!/usr/bin/env python3
"""Check optimized Swift Settings and the actual system audio output chooser, restoring the exact debug APK and private state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import xml.etree.ElementTree as ET

PACKAGE = 'com.doctordurant.xmwatch.android'
HARNESS = 'com.doctordurant.xmwatch.metareleaseharness'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--release-apk', required=True, type=Path)
    parser.add_argument('--harness-apk', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--run-checks-internal', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    args.output = args.output.resolve()
    args.release_apk = args.release_apk.resolve()
    args.harness_apk = args.harness_apk.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    sdk = Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))
    prefix = [str(sdk / 'platform-tools/adb'), '-s', args.serial]

    def adb(*command, check=True, timeout=60, binary=False):
        return subprocess.run(prefix + list(command), check=check, capture_output=True, text=not binary, timeout=timeout)

    def harness_absent():
        result = adb('shell', 'pm', 'path', HARNESS, check=False)
        if result.returncode not in (0, 1) or result.stderr.strip():
            raise RuntimeError('Could not inspect harness installation')
        return not result.stdout.strip()

    def installed_hash(package):
        paths = adb('shell', 'pm', 'path', package).stdout.strip().splitlines()
        assert len(paths) == 1 and paths[0].startswith('package:'), 'Expected a single installed APK for '+package
        return adb('shell', 'sha256sum', paths[0][8:]).stdout.split()[0]

    assert re.fullmatch(r'emulator-\d+', args.serial), 'Choose the dedicated emulator explicitly'
    assert adb('emu', 'avd', 'name').stdout.splitlines()[0].strip() == os.environ.get('RADIO_TEST_AVD', 'CadenceCarLibrary')
    assert int(adb('shell', 'getprop', 'ro.build.version.sdk').stdout.strip()) >= 34, 'API 34+ is required for this chooser check'
    if not args.run_checks_internal:
        (args.output / 'verification.json').unlink(missing_ok=True)
        command = [sys.executable, str(repo / 'scripts/run-radio-preserving-state.py'), '--serial', args.serial,
                   '--output', str(args.output / 'state-restoration.json'), '--', sys.executable, str(Path(__file__).resolve()),
                   '--serial', args.serial, '--release-apk', str(args.release_apk), '--harness-apk', str(args.harness_apk),
                   '--output', str(args.output), '--run-checks-internal']
        def interrupted(signum, frame):
            raise KeyboardInterrupt
        previous_term = signal.signal(signal.SIGTERM, interrupted)
        previous_int = signal.getsignal(signal.SIGINT)
        child = None
        try:
            child = subprocess.Popen(command)
            try:
                status = child.wait()
            except KeyboardInterrupt:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                if child.poll() is None: child.send_signal(signal.SIGTERM)
                child.wait(timeout=240)
                raise
            if status: raise subprocess.CalledProcessError(status, command)
        finally:
            signal.signal(signal.SIGTERM, previous_term)
            signal.signal(signal.SIGINT, previous_int)
        restoration = json.loads((args.output / 'state-restoration.json').read_text())
        assert restoration['privateFilePresenceAndBytesRestored'] and restoration['privateBackupEscrowRemoved']
        result = json.loads((args.output / 'optimized-audio-output-result.json').read_text())
        result['privateStateRestored'] = True
        (args.output / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
        print('PASS: optimized Swift Settings opened the system audio output chooser and Back returned; original APK and private state restored.')
        return

    # Outer escrow is established before any target install or private fixture change.
    adb('shell', 'run-as', PACKAGE, 'id')
    assert harness_absent(), 'Refuse to replace an existing harness installation'
    sdk = Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))
    build_tools = sorted((p for p in (sdk / 'build-tools').glob('*') if (p / 'aapt').exists()),
                         key=lambda p: tuple(map(int, re.findall(r'\d+', p.name))))[-1]
    java = dict(os.environ)
    java.setdefault('JAVA_HOME', '/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home')
    tested = args.output / 'tested'
    tested.mkdir(exist_ok=True)
    installed = adb('shell', 'pm', 'path', PACKAGE).stdout.strip().splitlines()
    assert len(installed) == 1 and installed[0].startswith('package:'), 'Expected a single installed APK'
    original = tested / 'original-installed-debug.apk'
    adb('pull', installed[0][8:], str(original))
    original_hash = hashlib.sha256(original.read_bytes()).hexdigest()

    def validate(apk, package, debuggable):
        badging = subprocess.run([str(build_tools / 'aapt'), 'dump', 'badging', str(apk)],
                                 check=True, capture_output=True, text=True).stdout
        assert re.search(r"package: name='" + re.escape(package) + "'", badging), 'Wrong APK package'
        assert ('application-debuggable' in badging) == debuggable, 'Wrong APK variant'
        certs = subprocess.run([str(build_tools / 'apksigner'), 'verify', '--print-certs', str(apk)],
                               check=True, capture_output=True, text=True, env=java).stdout
        return re.findall(r'certificate SHA-256 digest: ([a-f0-9]+)', certs)

    # Freeze the exact release and framework harness artifacts for this run.
    release = tested / 'optimized-release.apk'
    harness = tested / 'framework-harness.apk'
    for source, target in [(args.release_apk, release), (args.harness_apk, harness)]:
        if source.resolve() != target.resolve(): target.write_bytes(source.read_bytes())
    cert = validate(original, PACKAGE, True)
    assert len(cert) == 1 and cert == validate(release, PACKAGE, False) == validate(harness, HARNESS, True), 'APK certificates must match; never clear data to switch keys'
    checked = subprocess.run([sys.executable, str(repo / 'scripts/verify-android-meta-glasses-harness.py'), str(harness)],
                             check=True, capture_output=True, text=True)
    (args.output / 'harness-verification.json').write_text(checked.stdout)

    harness_installed = False
    target_replaced = False
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    previous_int = signal.getsignal(signal.SIGINT)

    try:
        # Keep account sessions intact and suppress optional last-channel
        # autoplay under the outer escrow. No channel is tuned by this harness.
        preferences = ET.Element('map')
        # SharedPreferences prefers a recovery .bak over the primary XML.
        for path in ('shared_prefs/defaults.xml.bak', 'shared_prefs/defaults.xml'):
            present = adb('shell', '-T', 'run-as', PACKAGE, 'test', '-f', path, check=False)
            assert present.returncode in (0, 1) and not present.stdout and not present.stderr, 'Unable to inspect autoplay preferences'
            if present.returncode == 0:
                raw = adb('shell', '-T', 'run-as', PACKAGE, 'cat', path, binary=True)
                preferences = ET.fromstring(raw.stdout)
                assert preferences.tag == 'map'
                break
        for node in list(preferences):
            if node.get('name') == 'xm.android.resumeLastChannel': preferences.remove(node)
        ET.SubElement(preferences, 'boolean', {'name': 'xm.android.resumeLastChannel', 'value': 'false'})
        payload = ET.tostring(preferences, encoding='utf-8', xml_declaration=True)
        adb('shell', '-T', 'run-as', PACKAGE, 'mkdir', '-p', 'shared_prefs')
        adb('shell', '-T', 'run-as', PACKAGE, 'rm', '-f', 'shared_prefs/defaults.xml.bak', 'shared_prefs/defaults.xml.new')
        subprocess.run(prefix + ['shell', '-T', 'run-as', PACKAGE, 'dd', 'of=shared_prefs/defaults.xml'],
                       input=payload, check=True, capture_output=True, timeout=30)
        seeded = ET.fromstring(adb('shell', '-T', 'run-as', PACKAGE, 'cat', 'shared_prefs/defaults.xml', binary=True).stdout)
        flags = [node for node in seeded if node.get('name') == 'xm.android.resumeLastChannel']
        assert len(flags) == 1 and flags[0].tag == 'boolean' and flags[0].get('value') == 'false'
        target_replaced = True
        adb('install', '-r', str(release))
        assert installed_hash(PACKAGE) == hashlib.sha256(release.read_bytes()).hexdigest(), 'Installed optimized APK differs from frozen artifact'
        harness_installed = True
        adb('install', str(harness))
        assert installed_hash(HARNESS) == hashlib.sha256(harness.read_bytes()).hexdigest(), 'Installed framework harness differs from frozen artifact'
        adb('shell', 'am', 'force-stop', PACKAGE)
        before = adb('shell', 'pidof', PACKAGE, check=False)
        assert before.returncode == 1 and not before.stdout.strip(), 'Target must start cold'
        run = adb('shell', 'am', 'instrument', '-w', '-r',
                  '-e', 'mode', 'audioOutput', '-e', 'allowAudioOutputOptimizedFixture', 'true',
                  HARNESS + '/.MetaGlassesInstrumentation', check=False, timeout=150)
        log = run.stdout + run.stderr
        (args.output / 'optimized-audio-output.log').write_text(log)
        diagnostics = adb('logcat', '-d', '-v', 'threadtime', '-t', '2500',
                          'AndroidRuntime:E', 'MetaGlassesInstrumentation:I', 'libc:F', 'DEBUG:F', '*:S', check=False)
        (args.output / 'optimized-audio-output-logcat.txt').write_text(diagnostics.stdout + diagnostics.stderr)
        assert run.returncode == 0 and 'INSTRUMENTATION_CODE: -1' in log, 'Inspect optimized-audio-output.log'
        for key, value in {'status': 'passed', 'mode': 'audioOutput', 'targetDebuggable': 'false',
                           'actualSwiftUIEntry': 'true', 'systemOutputDialog': 'true', 'dismissedToCaller': 'true',
                           'routeSelected': 'false', 'bluetoothPermissionRequested': 'false', 'sdkMockUsed': 'false',
                           'optimizedPlaybackStateTested': 'false'}.items():
            assert f'INSTRUMENTATION_RESULT: {key}={value}' in log, 'Missing result '+key+'; inspect optimized-audio-output.log'
        assert 'INSTRUMENTATION_RESULT: failure=' not in log and 'INSTRUMENTATION_RESULT: cleanupFailure=' not in log

    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            # The outer runner uses run-as for restoration. Restore this exact
            # debuggable APK first even if any optimized check or install failed.
            adb('shell', 'am', 'force-stop', PACKAGE, check=False)
            try:
                if target_replaced: adb('install', '-r', str(original))
                adb('shell', 'run-as', PACKAGE, 'id')
                assert installed_hash(PACKAGE) == original_hash, 'Original installed APK was not restored'
            finally:
                if harness_installed and not harness_absent(): adb('uninstall', HARNESS)
                adb('shell', 'am', 'force-stop', PACKAGE)
        finally:
            signal.signal(signal.SIGTERM, previous_term)
            signal.signal(signal.SIGINT, previous_int)
    assert harness_absent(), 'Harness cleanup incomplete'
    stopped = adb('shell', 'pidof', PACKAGE, check=False)
    assert stopped.returncode == 1 and not stopped.stdout.strip(), 'Target was not stopped after restoration'
    result = {'status': 'passed', 'serial': args.serial,
              'avd': os.environ.get('RADIO_TEST_AVD', 'CadenceCarLibrary'),
              'actualSystemOutputChecks': 1, 'targetNonDebuggableR8': True,
              'actualSwiftUIEntry': True, 'entry': 'Settings > Playback > Audio Output',
              'systemOutputDialog': True, 'dismissedToCaller': True,
              'routeSelected': False, 'bluetoothPermissionRequested': False,
              'olderAPIFallbackTested': False, 'physicalDeviceTested': False,
              'optimizedPlaybackStateTested': False, 'liveRadioTuneTested': False,
              'lastChannelAutoplaySuppressed': True, 'permissionChangesRequested': False,
              'frameworkInstrumentationInjected': True, 'sharedRuntimeClassesInjected': False,
              'sdkMockUsed': False, 'metaAIAccountUsed': False,
              'originalDebugAPKRestored': True, 'harnessRemoved': True,
              'appStoppedConfirmed': True, 'installedAppAndHarnessHashesMatched': True,
              'signerSHA256': cert[0],
              'originalAPK_SHA256': original_hash,
              'optimizedAPK_SHA256': hashlib.sha256(release.read_bytes()).hexdigest(),
              'harnessAPK_SHA256': hashlib.sha256(harness.read_bytes()).hexdigest()}
    (args.output / 'optimized-audio-output-result.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
