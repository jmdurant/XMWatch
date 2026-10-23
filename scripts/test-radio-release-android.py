#!/usr/bin/env python3
"""Verify the optimized app through its UI, OS media controls and AudioFlinger.

No test runtime is injected into the release process. Existing encrypted account
state is preserved. Requires an explicitly selected emulator and matching signer.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--apk', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if not re.fullmatch('emulator-[0-9]+', args.serial): parser.error('Select the test emulator explicitly.')
repo = Path(__file__).resolve().parents[1]
sdk = Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))
adb = [str(sdk/'platform-tools/adb'), '-s', args.serial]
pkg = 'com.doctordurant.xmwatch.android'
args.output.mkdir(parents=True, exist_ok=True)
def run(*command): return subprocess.run(adb+list(command), check=True, capture_output=True, text=True).stdout

def wait_for(callback, timeout=45):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        value = callback()
        if value: return value
        time.sleep(.3)
    raise RuntimeError('Release playback check timed out.')

def session():
    dump = run('shell','dumpsys','media_session')
    for chunk in re.split(r'\n(?=    \S)',dump):
        if '\n      package='+pkg+'\n' in chunk:
            state = re.search(r'state=PlaybackState \{state=([A-Z_]+)\((\d+)\)',chunk)
            meta = re.search(r'metadata: .*description=(.*)',chunk)
            return {'state':int(state.group(2)) if state else 0,'description':meta.group(1) if meta else ''}
    return {'state':0,'description':''}

def frames(active_only=True):
    pid = run('shell','pidof',pkg).strip()
    if not pid: return None
    dump = run('shell','dumpsys','media.audio_flinger')
    pattern = re.compile(r'^\s*(?:[A-Za-z]\s+)?(\d+)\s+(yes|no)\s+'+re.escape(pid)+r'/\s+\d+\s+.*?\b(?:true|false)\s+([0-9A-Fa-f]{8,})\s+\d+',re.M)
    for match in pattern.finditer(dump):
        if active_only and match.group(2)!='yes': continue
        return {'track':int(match.group(1)),'active':match.group(2)=='yes','frames':int(match.group(3),16)}
    return None

def hierarchy():
    run('shell','uiautomator','dump','/sdcard/test-owned-radio-release.xml')
    xml = run('exec-out','cat','/sdcard/test-owned-radio-release.xml')
    return xml, list(ET.fromstring(xml).iter('node'))

def play_coordinate():
    _,nodes=hierarchy()
    for node in nodes:
        if node.get('content-desc')=='Play SiriusXM Hits 1':
            x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds','')))
            return ((x1+x2)//2,(y1+y2)//2)
    return None

def labeled(label):
    _,nodes=hierarchy()
    return next((node for node in reversed(nodes)
        if node.get('text')==label or node.get('content-desc')==label),None)

def tap(node):
    x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds','')))
    run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))

def has_label(label):
    return labeled(label) is not None

def verify_channel(number):
    def ready():
        _,nodes=hierarchy()
        channel=any(node.get('text','').startswith(f'Channel {number} ·') for node in nodes)
        return channel and session()['state']==3 and frames()
    before=wait_for(ready)
    time.sleep(1)
    after=wait_for(frames)
    if before['track']==after['track'] and (after['frames']-before['frames'])%(2**32)<22050:
        raise RuntimeError('Channel changed on screen without advancing decoded output.')

def open_media_notification():
    run('shell','cmd','statusbar','expand-notifications')
    def title_node():
        title=session()['description'].split(',')[0]
        _,nodes=hierarchy()
        # Android's media card identifies the owning app independently of the
        # song text, which can change between the session and hierarchy reads.
        card=next((node for node in nodes if node.get('content-desc','').endswith('from XMWatch')),None)
        if card is not None: return card
        node=next((node for node in nodes if title and node.get('text','').startswith(title)),None)
        return node if node is not None else False
    # ElementTree leaf nodes are false-y; explicitly preserve found nodes.
    deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        node=title_node()
        if node is not False:
            tap(node)
            wait_for(lambda:has_label('Next Channel'))
            return
    raise RuntimeError('The active media notification was not found.')

def dispatch(command):
    dump=run('shell','dumpsys','media_session')
    button=re.search(r'Media button session is ([^\n]+)',dump)
    if not button or pkg not in button.group(1): raise RuntimeError('XMWatch does not own the media-button session.')
    run('shell','cmd','media_session','dispatch',command)

success=False
try:
    env=dict(os.environ,ANDROID_HOME=str(sdk))
    static=json.loads(subprocess.check_output(['python3',str(repo/'scripts/verify-android-apk.py'),str(args.apk),'--release','--abi','arm64-v8a'],env=env,text=True))
    assert static['package']==pkg and not static['debuggable']
    run('shell','cmd','statusbar','collapse')
    run('shell','am','force-stop',pkg)
    run('install','-r',str(args.apk))
    run('shell','am','start','-W','-n',pkg+'/xmwatch.android.MainActivity')
    coordinate=wait_for(play_coordinate)
    run('shell','input','tap',str(coordinate[0]),str(coordinate[1]))
    wait_for(lambda:session()['state']==3)
    initial=wait_for(frames)
    def metadata_ready():
        state=session()
        if state['state']==3 and state['description'] and not state['description'].startswith('SiriusXM Hits 1, Pop,'):
            return state
        return None
    metadata=wait_for(metadata_ready,60)
    # Check app buttons using a fresh external hierarchy at the moment of tap.
    next_button=labeled('Next Channel')
    if next_button is None: raise RuntimeError('Next Channel is missing.')
    tap(next_button)
    verify_channel(3)
    previous_button=labeled('Previous Channel')
    if previous_button is None: raise RuntimeError('Previous Channel is missing.')
    tap(previous_button)
    verify_channel(2)
    channels=labeled('Channels')
    if channels is None: raise RuntimeError('Channels tab is missing.')
    tap(channels)
    wait_for(lambda:has_label('Play SiriusXM Hits 1'))
    run('shell','input','keyevent','KEYCODE_HOME')
    before=wait_for(frames)
    time.sleep(10)
    after=wait_for(frames)
    if before['track']!=after['track'] or (after['frames']-before['frames'])%(2**32)<220500:
        raise RuntimeError('Optimized audio output did not advance in the background.')
    foreground='isForeground=true' in run('shell','dumpsys','activity','services',pkg)
    if not foreground: raise RuntimeError('Playback service was not foreground.')
    dispatch('pause')
    wait_for(lambda:session()['state']==2)
    time.sleep(1.5)
    if frames(): raise RuntimeError('Audio track remained active after Pause.')
    dispatch('play')
    wait_for(lambda:session()['state']==3)
    resumed=wait_for(frames)
    time.sleep(2)
    resumed_after=wait_for(frames)
    if resumed_after['track']!=resumed['track'] or (resumed_after['frames']-resumed['frames'])%(2**32)<22050:
        raise RuntimeError('Optimized audio output did not resume.')
    open_media_notification()
    dispatch('next')
    verify_channel(3)
    dispatch('previous')
    verify_channel(2)
    dispatch('pause')
    wait_for(lambda:session()['state']==2)
    result={'static':static,'savedSessionRestored':True,'metadataPublished':True,
        'backgroundFrames':(after['frames']-before['frames'])%(2**32),'foregroundService':foreground,
        'systemPauseResume':True,'uiNextPreviousDecoded':True,'systemNextPreviousDecoded':True,'actualNotificationOpenedNowPlaying':True,
        'testRuntimeInjected':False,'playbackLeftPaused':True}
    (args.output/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    success=True
    print(json.dumps(result,indent=2))
finally:
    if not success:
        try:
            xml,_=hierarchy()
            (args.output/'failure-ui.xml').write_text(xml)
            with (args.output/'failure-screen.png').open('wb') as output:
                subprocess.run(adb+['exec-out','screencap','-p'],stdout=output,check=True)
        except Exception:
            pass
    run('shell','rm','-f','/sdcard/test-owned-radio-release.xml')
    if not success: run('shell','am','force-stop',pkg)
