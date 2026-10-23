#!/usr/bin/env python3
"""Opt-in live radio check using an already encrypted, authorized emulator session."""
import argparse
from pathlib import Path
import json
import os
import re
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--verify-renewal', action='store_true')
parser.add_argument('--verify-recovery', action='store_true')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
if not re.fullmatch('emulator-[0-9]+', args.serial):
    parser.error('Choose the ARM64 test emulator explicitly.')
repo = Path(__file__).resolve().parents[1]
sdk = Path(os.environ.get('ANDROID_HOME', '/opt/homebrew/share/android-commandlinetools'))
adb = [str(sdk/'platform-tools/adb'), '-s', args.serial]
pkg = 'com.doctordurant.xmwatch.android'
output = args.output or repo/'build/android/evidence/playback'
output.mkdir(parents=True, exist_ok=True)
def run(*command):
    return subprocess.run(adb+list(command), check=True, capture_output=True, text=True).stdout

# Collect coordinates from a fresh platform hierarchy before instrumentation.
# Skip's virtual accessibility nodes can retain stale bounds inside instrumentation.
def find(label):
    for _ in range(12):
        run('shell', 'uiautomator', 'dump', '/sdcard/test-owned-radio-ui.xml')
        xml = run('exec-out', 'cat', '/sdcard/test-owned-radio-ui.xml')
        nodes = list(ET.fromstring(xml).iter('node'))
        if label == 'Next Channel' and any(n.get('text') == 'Connecting…' for n in nodes):
            time.sleep(.3)
            continue
        for node in (reversed(nodes) if label == 'Channels' else nodes):
            if node.get('content-desc') == label or node.get('text') == label:
                x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds','')))
                if x2>x1 and y2>y1: return f'{(x1+x2)//2},{(y1+y2)//2}'
        time.sleep(.3)
    raise RuntimeError('Expected radio control did not appear; saved session may need attention.')
passed = False
try:
    run('shell', 'am', 'force-stop', pkg)
    run('shell', 'am', 'start', '-W', '-n', pkg+'/xmwatch.android.MainActivity')
    first = find('Play SiriusXM Hits 1')
    channels_tab = find('Channels')
    run('shell', 'input', 'tap', *first.split(','))
    next_button = find('Next Channel')
    (output/'ui-coordinates.json').write_text(json.dumps({'play':first,'next':next_button,'channelsTab':channels_tab},indent=2)+'\n')
    command = adb+['shell','am','instrument','-w','-e','allowLiveRadio','true','-e','playTap',first,'-e','channelsTap',channels_tab,
                   '-e','nextTap',next_button,'-e','verifyRenewal',str(args.verify_renewal).lower(),
                   '-e','verifyRecovery',str(args.verify_recovery).lower(),'-e','class','xmwatch.android.RadioLivePlaybackTest',
                   pkg+'.test/androidx.test.runner.AndroidJUnitRunner']
    with (output/'live-instrumentation.log').open('w') as log:
        subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=900 if args.verify_renewal else 180)
    result = (output/'live-instrumentation.log').read_text()
    if 'OK (1 test)' not in result: raise RuntimeError('Live playback check failed; see its sanitized instrumentation log.')
    passed = True
    print(result)
finally:
    if not passed:
        try:
            run('shell','uiautomator','dump','/sdcard/test-owned-radio-ui.xml')
            (output/'failure-ui.xml').write_text(run('exec-out','cat','/sdcard/test-owned-radio-ui.xml'))
            with (output/'failure-screen.png').open('wb') as screenshot:
                subprocess.run(adb+['exec-out','screencap','-p'],stdout=screenshot,check=True)
        except subprocess.CalledProcessError:
            pass
    run('shell','rm','-f','/sdcard/test-owned-radio-ui.xml')
    if not passed: run('shell','am','force-stop',pkg)
