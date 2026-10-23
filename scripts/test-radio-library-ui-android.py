#!/usr/bin/env python3
"""Exercise search and a reversible local favorite on the signed-in debug emulator."""
import argparse
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
if not re.fullmatch('emulator-[0-9]+',args.serial): parser.error('Select the emulator explicitly.')
adb=[str(Path(os.environ.get('ANDROID_HOME','/opt/homebrew/share/android-commandlinetools'))/'platform-tools/adb'),'-s',args.serial]
pkg='com.doctordurant.xmwatch.android'
def run(*command):return subprocess.run(adb+list(command),check=True,capture_output=True,text=True).stdout

def nodes():
    run('shell','uiautomator','dump','/sdcard/test-owned-radio-library.xml')
    return list(ET.fromstring(run('exec-out','cat','/sdcard/test-owned-radio-library.xml')).iter('node'))

def wait(callback,timeout=30):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=callback()
        if isinstance(value, ET.Element) or value:return value
        time.sleep(.3)
    raise RuntimeError('Library UI check timed out.')

def tap(node):
    x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds','')))
    run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))

def labeled(label):return next((n for n in nodes() if n.get('content-desc')==label or n.get('text')==label),None)

def play_names():return {n.get('content-desc')[5:] for n in nodes() if (n.get('content-desc') or '').startswith('Play ')}

def favorites_value():
    xml=run('exec-out','run-as',pkg,'cat','shared_prefs/defaults.xml')
    values={n.get('name'):n.text for n in ET.fromstring(xml)}
    return set(json.loads(values.get('xm.android.favorites') or '[]'))

original=favorites_value()
changed=False
fixture=None
try:
    run('shell','am','force-stop',pkg)
    run('shell','am','start','-W','-n',pkg+'/xmwatch.android.MainActivity')
    wait(lambda:labeled('Play SiriusXM Hits 1'))
    tap(wait(lambda:next((n for n in nodes() if n.get('class')=='android.widget.EditText'),None)))
    run('shell','input','text','Beatles')
    run('shell','input','keyevent','KEYCODE_BACK')
    filtered=wait(lambda:(values if values and all('beatles' in value.lower() for value in values) else None) if (values:=play_names()) else None)
    fixture=sorted(filtered)[0]
    # The preference values are inspected only to preserve the original local set.
    # No service-side favorites or account data are edited.
    before=favorites_value()
    tap(wait(lambda:labeled('Favorite '+fixture)))
    wait(lambda:favorites_value()!=before)
    changed=True
    toggled=favorites_value()
    cancel=labeled('Cancel')
    if cancel is not None:tap(cancel)
    tap(wait(lambda:labeled('Favorites')))
    expected_added=len(toggled)>len(before)
    wait(lambda:(fixture in play_names())==expected_added)
    # Undo through the same channel row, then verify the exact original preference set.
    if expected_added:
        tap(wait(lambda:labeled('Favorite '+fixture)))
    else:
        tap(wait(lambda:labeled('Channels')))
        tap(wait(lambda:next((n for n in nodes() if n.get('class')=='android.widget.EditText'),None)))
        run('shell','input','text','Beatles')
        run('shell','input','keyevent','KEYCODE_BACK')
        tap(wait(lambda:labeled('Favorite '+fixture)))
    wait(lambda:favorites_value()==original)
    changed=False
    empty_verified=expected_added and not original
    if empty_verified:wait(lambda:labeled('No Favorites Yet'))
    args.output.mkdir(parents=True,exist_ok=True)
    result={'searchFiltered':True,'filteredCount':len(filtered),'favoriteToggle':True,'favoritesTabUpdated':True,'originalFavoritesRestored':True,'emptyFavoritesStateVerified':empty_verified}
    (args.output/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
finally:
    if changed and fixture:
        # Best-effort UI undo, followed by an explicit preservation assertion.
        current=favorites_value()
        if current!=original:
            row=labeled('Favorite '+fixture)
            if row is not None:tap(row)
        if favorites_value()!=original:
            # Restore only this local preference if a broken UI cannot undo it.
            # Stop the process first so an outstanding apply() cannot overwrite it.
            run('shell','am','force-stop',pkg)
            xml=run('exec-out','run-as',pkg,'cat','shared_prefs/defaults.xml')
            root=ET.fromstring(xml)
            entry=next((n for n in root if n.get('name')=='xm.android.favorites'),None)
            if entry is None:entry=ET.SubElement(root,'string',{'name':'xm.android.favorites'})
            entry.text=json.dumps(sorted(original))
            payload=ET.tostring(root,encoding='utf-8',xml_declaration=True)
            subprocess.run(adb+['shell','-T','run-as',pkg,'dd','of=shared_prefs/defaults.xml'],input=payload,check=True,capture_output=True)
            assert favorites_value()==original, 'Original local favorites could not be restored.'
            run('shell','am','start','-W','-n',pkg+'/xmwatch.android.MainActivity')
    run('shell','rm','-f','/sdcard/test-owned-radio-library.xml')
