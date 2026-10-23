#!/usr/bin/env python3
"""Check optimized Debug Mode persistence, restoring the exact APK and private preferences."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PACKAGE = 'com.doctordurant.xmwatch.android'
REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--release-apk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--playback', action='store_true', help='Also run existing optimized live playback regression.')
    parser.add_argument('--internal', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.release_apk = args.release_apk.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    sdk = Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))
    prefix = [str(sdk/'platform-tools/adb'), '-s', args.serial]

    def adb(*command, check=True, binary=False):
        return subprocess.run(prefix+list(command), check=check, capture_output=True, text=not binary, timeout=60)

    assert re.fullmatch(r'emulator-\d+', args.serial)
    assert adb('emu', 'avd', 'name').stdout.splitlines()[0].strip() == 'CadenceCarLibrary'
    if not args.internal:
        (args.output/'verification.json').unlink(missing_ok=True)
        command = [sys.executable, str(REPO/'scripts/run-radio-preserving-state.py'), '--serial', args.serial,
                   '--output', str(args.output/'state-restoration.json'), '--', sys.executable, str(Path(__file__).resolve()),
                   '--serial', args.serial, '--release-apk', str(args.release_apk), '--output', str(args.output), '--internal']
        if args.playback: command.append('--playback')
        def interrupted(signum, frame): raise KeyboardInterrupt
        old_term = signal.signal(signal.SIGTERM, interrupted)
        child = subprocess.Popen(command)
        try:
            status = child.wait()
        except KeyboardInterrupt:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            child.send_signal(signal.SIGTERM)
            child.wait(timeout=240)
            raise
        finally:
            signal.signal(signal.SIGTERM, old_term)
        if status: raise subprocess.CalledProcessError(status, command)
        restored = json.loads((args.output/'state-restoration.json').read_text())
        assert restored['privateFilePresenceAndBytesRestored'] and restored['privateBackupEscrowRemoved']
        result = json.loads((args.output/'optimized-result.json').read_text())
        result['privateStateRestored'] = True
        (args.output/'verification.json').write_text(json.dumps(result, indent=2)+'\n')
        print('PASS: optimized Debug Mode persisted on/off; original APK and private state restored.')
        return

    adb('shell', 'run-as', PACKAGE, 'id')
    tested = args.output/'tested'
    tested.mkdir(exist_ok=True)
    installed = adb('shell', 'pm', 'path', PACKAGE).stdout.strip().splitlines()
    assert len(installed) == 1 and installed[0].startswith('package:')
    original = tested/'original-installed-debug.apk'
    adb('pull', installed[0][8:], str(original))
    original_hash = hashlib.sha256(original.read_bytes()).hexdigest()
    release = tested/'optimized-release.apk'
    if args.release_apk != release: release.write_bytes(args.release_apk.read_bytes())
    checked = subprocess.run([sys.executable, str(REPO/'scripts/verify-android-apk.py'), str(release), '--release', '--abi', 'arm64-v8a'], check=True, capture_output=True, text=True)
    static = json.loads(checked.stdout)
    assert static['package'] == PACKAGE and not static['debuggable']
    tools = sorted((p for p in (sdk/'build-tools').glob('*') if (p/'apksigner').exists()), key=lambda p: tuple(map(int,re.findall(r'\d+',p.name))))[-1]
    env = dict(os.environ)
    env.setdefault('JAVA_HOME','/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home')
    def cert(path):
        result = subprocess.run([str(tools/'apksigner'),'verify','--print-certs',str(path)],check=True,capture_output=True,text=True,env=env)
        return re.findall(r'certificate SHA-256 digest: ([a-f0-9]+)',result.stdout)
    assert len(cert(original)) == 1 and cert(original) == cert(release)
    changed = False
    old_term = signal.signal(signal.SIGTERM, lambda signum,frame: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        # The guardian has stopped the app and escrowed every preference variant.
        preferences = ET.Element('map')
        for path in ('shared_prefs/defaults.xml.bak','shared_prefs/defaults.xml'):
            present = adb('shell','-T','run-as',PACKAGE,'test','-f',path,check=False)
            assert present.returncode in (0,1) and not present.stderr
            if present.returncode == 0:
                preferences = ET.fromstring(adb('shell','-T','run-as',PACKAGE,'cat',path,binary=True).stdout)
                break
        assert preferences.tag == 'map'
        for node in list(preferences):
            if node.get('name') in ('xm.android.resumeLastChannel','xm.android.debugMode'): preferences.remove(node)
        for key in ('xm.android.resumeLastChannel','xm.android.debugMode'):
            ET.SubElement(preferences,'boolean',{'name':key,'value':'false'})
        adb('shell','-T','run-as',PACKAGE,'mkdir','-p','shared_prefs')
        adb('shell','-T','run-as',PACKAGE,'rm','-f','shared_prefs/defaults.xml.bak','shared_prefs/defaults.xml.new')
        subprocess.run(prefix+['shell','-T','run-as',PACKAGE,'dd','of=shared_prefs/defaults.xml'],input=ET.tostring(preferences,encoding='utf-8',xml_declaration=True),check=True,capture_output=True,timeout=30)
        changed = True
        adb('install','-r',str(release))
        current = adb('shell','pm','path',PACKAGE).stdout.strip().removeprefix('package:')
        release_hash = hashlib.sha256(release.read_bytes()).hexdigest()
        assert adb('shell','sha256sum',current).stdout.split()[0] == release_hash
        if args.playback:
            subprocess.run([sys.executable,str(REPO/'scripts/test-radio-release-android.py'),'--serial',args.serial,'--apk',str(release),'--output',str(args.output/'playback')],check=True,timeout=360)
        def tree():
            adb('shell','uiautomator','dump','/sdcard/test-owned-xm-parity.xml')
            return ET.fromstring(adb('exec-out','cat','/sdcard/test-owned-xm-parity.xml').stdout)
        def tap(node, root=None):
            if root is not None:
                parents = {child:parent for parent in root.iter() for child in parent}
                candidate = node
                while candidate.get('clickable') != 'true' and candidate in parents:
                    candidate = parents[candidate]
                if candidate.get('clickable') == 'true': node = candidate
            x1,y1,x2,y2 = map(int,re.findall(r'\d+',node.get('bounds','')))
            adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
        def switch(root):
            parents = {child:parent for parent in root.iter() for child in parent}
            label = next((n for n in root.iter('node') if n.get('text')=='Debug Mode' or n.get('content-desc')=='Debug Mode'),None)
            row = label
            while row is not None:
                switches = [n for n in row.iter('node') if n.get('checkable')=='true']
                if len(switches)==1: return switches[0]
                row = parents.get(row)
            return None
        def open_settings():
            adb('shell','am','force-stop',PACKAGE)
            adb('shell','am','start','-W','-n',PACKAGE+'/xmwatch.android.MainActivity')
            deadline = time.monotonic()+60
            while time.monotonic()<deadline:
                root=tree()
                # A cached sign-in form can briefly show Debug Mode while the
                # saved account is still restoring. Wait for signed-in Settings
                # instead of treating that transient form as the destination.
                if any(n.get('text') in ('Appearance','Resume Last Channel') for n in root.iter('node')):
                    node=switch(root)
                    if node is not None: return node
                    break
                settings=next((n for n in reversed(list(root.iter('node'))) if n.get('text')=='Settings' or n.get('content-desc')=='Settings'),None)
                if settings is not None:
                    # Cached Compose navigation can replace its initial tab bar
                    # during account restoration; wait for stable bounds and
                    # click the actionable ancestor instead of the text child.
                    bounds=settings.get('bounds')
                    time.sleep(.4)
                    stable=tree()
                    fresh=next((n for n in reversed(list(stable.iter('node'))) if (n.get('text')=='Settings' or n.get('content-desc')=='Settings') and n.get('bounds')==bounds),None)
                    if fresh is not None: tap(fresh,stable)
                time.sleep(.5)
            for attempt in range(7):
                root=tree(); node=switch(root)
                if node is not None: return node
                adb('shell','input','swipe','500','1500','500','550','250')
            controlled={'Settings','Playback','Appearance','Region','Account','Diagnostics','Debug Mode','Channels','Favorites','Now Playing','Meta Glasses','Audio Output'}
            nodes=[{k:n.get(k) for k in ('class','text','content-desc','checkable','checked','clickable','bounds')} for n in root.iter('node') if n.get('text') in controlled or n.get('content-desc') in controlled or n.get('checkable')=='true']
            (args.output/'failure-controls.json').write_text(json.dumps(nodes,indent=2)+'\n')
            raise RuntimeError('Debug Mode switch unavailable; controlled labels saved')
        def expect(value):
            end=time.monotonic()+10
            while time.monotonic()<end:
                node=switch(tree())
                if node is not None and (node.get('checked')=='true') == value: return node
                time.sleep(.3)
            raise RuntimeError('Debug Mode switch state did not match')
        node=open_settings(); assert node.get('checked')=='false'
        tap(node); expect(True)
        assert open_settings().get('checked')=='true'
        tap(expect(True)); expect(False)
        assert open_settings().get('checked')=='false'
        # This settings-only check must never start playback.
        if not args.playback:
            session=adb('shell','dumpsys','media_session').stdout
            for chunk in re.split(r'\n(?=    \S)',session):
                if '\n      package='+PACKAGE+'\n' in chunk:
                    assert not re.search(r'state=PlaybackState \{state=PLAYING\(3\)',chunk)
        result={'status':'passed','optimizedAPK_SHA256':release_hash,'originalAPK_SHA256':original_hash,
                'nonDebuggable':True,'debugModeInitiallySeededOff':True,'debugModePersistedOn':True,'debugModePersistedOff':True,
                'originalDebugAPKRestored':True,'testRuntimeInjected':False,'physicalDeviceTested':False,
                'optionalLivePlaybackRegression':args.playback,'lastChannelAutoplaySuppressed':True}
    finally:
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        signal.signal(signal.SIGINT,signal.SIG_IGN)
        try:
            adb('shell','am','force-stop',PACKAGE,check=False)
            if changed: adb('install','-r',str(original))
            adb('shell','run-as',PACKAGE,'id')
            current=adb('shell','pm','path',PACKAGE).stdout.strip().removeprefix('package:')
            assert adb('shell','sha256sum',current).stdout.split()[0]==original_hash
            adb('shell','rm','-f','/sdcard/test-owned-xm-parity.xml')
            adb('shell','am','force-stop',PACKAGE)
        finally:
            signal.signal(signal.SIGTERM,old_term)
            signal.signal(signal.SIGINT,signal.default_int_handler)
    (args.output/'optimized-result.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__': main()
