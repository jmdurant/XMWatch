#!/usr/bin/env python3
"""Exercise saved-cookie retry and opt-in channel resumption on an owned emulator.

Blocks networking for XMWatch alone, restores the original firewall and local
playback preferences, and never clears the app or replaces encrypted cookies.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser=argparse.ArgumentParser()
parser.add_argument('--serial',required=True)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args()
if not re.fullmatch('emulator-[0-9]+',args.serial):parser.error('Select the test emulator explicitly.')
adb=[str(Path(os.environ.get('ANDROID_HOME','/opt/homebrew/share/android-commandlinetools'))/'platform-tools/adb'),'-s',args.serial]
pkg='com.doctordurant.xmwatch.android'
args.output.mkdir(parents=True,exist_ok=True)
def run(*command):return subprocess.run(adb+list(command),check=True,capture_output=True,text=True).stdout

def wait(callback,timeout=45):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=callback()
        if isinstance(value,ET.Element) or value:return value
        time.sleep(.3)
    raise RuntimeError('Saved-session UI check timed out.')

def nodes():
    run('shell','uiautomator','dump','/sdcard/test-owned-radio-session.xml')
    return list(ET.fromstring(run('exec-out','cat','/sdcard/test-owned-radio-session.xml')).iter('node'))

def labeled(label):return next((n for n in reversed(nodes()) if n.get('text')==label or n.get('content-desc')==label),None)
def ready(label):
    n=labeled(label)
    return n if n is not None and n.get('enabled')=='true' else None

def tap(node):
    x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds','')))
    run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))

def preferences():return ET.fromstring(run('exec-out','run-as',pkg,'cat','shared_prefs/defaults.xml'))
def pref(key):return next((n for n in preferences() if n.get('name')==key),None)
def resume_enabled():
    value=pref('xm.android.resumeLastChannel')
    return value is not None and (value.get('value')=='true' or value.text=='true')

def set_resume(value):
    tap(wait(lambda:labeled('Settings')))
    if resume_enabled()!=value:tap(wait(lambda:next((n for n in nodes() if n.get('checkable')=='true'),None)))
    wait(lambda:resume_enabled()==value)

def start():run('shell','am','start','-W','-n',pkg+'/xmwatch.android.MainActivity')
def cold():run('shell','am','force-stop',pkg);start()
def state():
    dump=run('shell','dumpsys','media_session')
    for chunk in re.split(r'\n(?=    \S)',dump):
        if '\n      package='+pkg+'\n' in chunk:
            match=re.search(r'state=PlaybackState \{state=[A-Z_]+\((\d+)\)',chunk)
            return int(match.group(1)) if match else 0
    return 0

def audio_frames():
    pid=run('shell','pidof',pkg).strip()
    if not pid:return None
    pattern=r'^\s*(?:[A-Za-z]\s+)?(\d+)\s+yes\s+'+re.escape(pid)+r'/\s+\d+\s+.*?\b(?:true|false)\s+([0-9A-Fa-f]{8,})\s+\d+'
    match=re.search(pattern,run('shell','dumpsys','media.audio_flinger'),re.M)
    return (int(match[1]),int(match[2],16)) if match else None

def network(enabled):
    run('shell','cmd','connectivity','set-package-networking-enabled',str(enabled).lower(),pkg)
    run('shell','cmd','connectivity','set-chain3-enabled','true')
    expected='allow' if enabled else 'deny'
    assert run('shell','cmd','connectivity','get-package-networking-enabled',pkg).strip()==pkg+':'+expected

keys=('xm.android.resumeLastChannel','xm.android.lastChannel')
original={key:copy.deepcopy(pref(key)) for key in keys}
chain=run('shell','cmd','connectivity','get-chain3-enabled').strip()
policy=run('shell','cmd','connectivity','get-package-networking-enabled',pkg).strip()
assert chain in ('chain:enabled','chain:disabled') and policy in (pkg+':allow',pkg+':deny')
assert policy==pkg+':allow','Start with XMWatch networking enabled.'
success=False
try:
    cold()
    wait(lambda:labeled('Play SiriusXM Hits 1'))
    print('stage=enable-resume',flush=True)
    set_resume(True)
    tap(wait(lambda:labeled('Channels')))
    tap(wait(lambda:labeled('Play SiriusXM Hits 1')))
    wait(lambda:state()==3)
    wait(lambda:pref('xm.android.lastChannel') is not None)
    cold()
    wait(lambda:state()==3 and any(n.get('text','').startswith('Channel 2 ·') for n in nodes()))
    before=wait(audio_frames)
    time.sleep(1)
    after=wait(audio_frames)
    assert before[0]==after[0] and (after[1]-before[1])%(2**32)>22050,'Resumed audio did not advance.'
    print('stage=resumed-channel-decoded',flush=True)
    set_resume(False)
    cold()
    wait(lambda:labeled('Play SiriusXM Hits 1'))
    assert state()!=3,'Disabled resume must not start playback.'
    run('shell','am','force-stop',pkg)
    print('stage=block-own-app-network',flush=True)
    network(False)
    start()
    wait(lambda:ready('Retry Saved Session'),75)
    assert labeled('Restoring saved session…') is None,'Wait for the failed restore to finish.'
    run('exec-out','run-as',pkg,'test','-s','shared_prefs/radio-session.xml')
    print('stage=retry-preserved-cookie',flush=True)
    network(True)
    run('shell','cmd','connectivity','set-chain3-enabled','true' if chain=='chain:enabled' else 'false')
    tap(wait(lambda:ready('Retry Saved Session')))
    wait(lambda:labeled('Play SiriusXM Hits 1'))
    pid=run('shell','pidof',pkg).strip()
    logs=run('logcat','-d','--pid',pid,'-s','com.doctordurant.xmwatch.android/XMWatchAndroid:I')
    assert 'stage=authentication' not in logs,'Retry unexpectedly attempted password authentication.'
    assert 'stage=session http=200' in logs and 'stage=channels http=200' in logs
    assert not resume_enabled() and state()!=3
    result={'resumeSettingPersisted':True,'lastChannelResumedAfterColdStart':True,
        'resumedChannelDecodedAudio':True,'disabledResumeStayedSilent':True,'realNetworkFailureShowedCookieRetry':True,
        'retryRestoredChannelsWithoutCredentials':True,'passwordAuthenticationRequests':0,
        'encryptedSessionPreserved':True}
    (args.output/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    success=True
finally:
    run('shell','cmd','connectivity','set-package-networking-enabled','true' if policy.endswith(':allow') else 'false',pkg)
    run('shell','cmd','connectivity','set-chain3-enabled','true' if chain=='chain:enabled' else 'false')
    if not success:
        try:
            (args.output/'failure-ui.xml').write_text(ET.tostring(ET.Element('hierarchy'),encoding='unicode'))
            run('shell','uiautomator','dump','/sdcard/test-owned-radio-session.xml')
            (args.output/'failure-ui.xml').write_text(run('exec-out','cat','/sdcard/test-owned-radio-session.xml'))
            with (args.output/'failure-screen.png').open('wb') as target:
                subprocess.run(adb+['exec-out','screencap','-p'],stdout=target,check=True)
        except subprocess.CalledProcessError:pass
    run('shell','am','force-stop',pkg)
    root=preferences()
    for key,value in original.items():
        for old in list(root):
            if old.get('name')==key:root.remove(old)
        if value is not None:root.append(value)
    subprocess.run(adb+['shell','-T','run-as',pkg,'dd','of=shared_prefs/defaults.xml'],
        input=ET.tostring(root,encoding='utf-8',xml_declaration=True),check=True,capture_output=True)
    run('exec-out','run-as',pkg,'test','-s','shared_prefs/radio-session.xml')
    run('shell','rm','-f','/sdcard/test-owned-radio-session.xml')
    start()
