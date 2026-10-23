#!/usr/bin/env python3
"""Opt-in channel/filter, offline refresh and appearance UI checks on an emulator."""
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
parser.add_argument('--appearance-only',action='store_true')
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
    raise RuntimeError('Browsing UI check timed out.')

def nodes():
    run('shell','uiautomator','dump','/sdcard/test-owned-radio-browsing.xml')
    return list(ET.fromstring(run('exec-out','cat','/sdcard/test-owned-radio-browsing.xml')).iter('node'))

def labeled(label):return next((n for n in reversed(nodes()) if n.get('text')==label or n.get('content-desc')==label),None)
def tap(node):
    x1,y1,x2,y2=map(int,re.findall(r'\d+',node.get('bounds','')))
    run('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
def preferences():return ET.fromstring(run('exec-out','run-as',pkg,'cat','shared_prefs/defaults.xml'))
def appearance():return next((n.text for n in preferences() if n.get('name')=='xm.android.appearance'),'system')
def cold():
    run('shell','am','force-stop',pkg)
    run('shell','am','start','-W','-n',pkg+'/xmwatch.android.MainActivity')
    wait(lambda:labeled('Play SiriusXM Hits 1'))
def screenshot(name):
    with (args.output/name).open('wb') as target:subprocess.run(adb+['exec-out','screencap','-p'],stdout=target,check=True)

def choose_category(name):
    tap(wait(lambda:labeled('Channel Category')))
    for _ in range(12):
        option=labeled(name)
        if option is not None:tap(option);return
        run('shell','input','swipe','540','1800','540','650','350')
    raise RuntimeError('Requested category was not found.')

def play_rows():
    rows=[]
    for n in nodes():
        if n.get('clickable')!='true':continue
        descendants=list(n.iter('node'))
        if any(c.get('content-desc','').startswith('Play ') for c in descendants):
            rows.append([c.get('text') for c in descendants if c.get('text')])
    return rows

def choose_appearance(value):
    tap(wait(lambda:labeled('Settings')))
    tap(wait(lambda:labeled('Appearance')))
    tap(wait(lambda:labeled(value.title())))
    wait(lambda:appearance()==value)

original=next((copy.deepcopy(n) for n in preferences() if n.get('name')=='xm.android.appearance'),None)
chain=run('shell','cmd','connectivity','get-chain3-enabled').strip()
policy=run('shell','cmd','connectivity','get-package-networking-enabled',pkg).strip()
assert chain in ('chain:enabled','chain:disabled') and policy==pkg+':allow'
success=False
try:
    cold()
    rows=[]
    if not args.appearance_only:
        print('stage=category-and-query',flush=True)
        choose_category('Rock')
        rows=wait(lambda:(r if r and all('Rock' in row for row in r) else None) if (r:=play_rows()) else None)
        field=wait(lambda:next((n for n in nodes() if n.get('class')=='android.widget.EditText'),None))
        tap(field);run('shell','input','text','NoSuchChannelZZZZ');run('shell','input','keyevent','KEYCODE_BACK')
        wait(lambda:labeled('No Matching Channels'))
        tap(wait(lambda:labeled('Clear Filters')))
        wait(lambda:labeled('Play SiriusXM Hits 1'))
        assert labeled('All Categories') is not None
        fields=[n for n in nodes() if n.get('class')=='android.widget.EditText']
        assert fields and not fields[0].get('text'),'Clear Filters left stale text in Search.'
        cancel=labeled('Cancel')
        if cancel is not None:tap(cancel)
        print('stage=offline-refresh',flush=True)
        run('shell','cmd','connectivity','set-package-networking-enabled','false',pkg)
        run('shell','cmd','connectivity','set-chain3-enabled','true')
        tap(wait(lambda:labeled('Refresh')))
        wait(lambda:labeled("Couldn't refresh channels. Try again."),75)
        assert labeled('Play SiriusXM Hits 1') is not None,'A failed refresh removed existing channels.'
        run('shell','cmd','connectivity','set-package-networking-enabled','true',pkg)
        run('shell','cmd','connectivity','set-chain3-enabled','true' if chain=='chain:enabled' else 'false')
        tap(wait(lambda:labeled('Refresh')))
        wait(lambda:labeled('Refreshing channels…') is None and labeled("Couldn't refresh channels. Try again.") is None)
        assert labeled('Play SiriusXM Hits 1') is not None
    print('stage=appearance',flush=True)
    choose_appearance('dark');cold();assert appearance()=='dark';screenshot('dark.png')
    choose_appearance('light');cold();assert appearance()=='light';screenshot('light.png')
    result={'scope':'appearance-only' if args.appearance_only else 'full-browsing','categoryFiltered':None if args.appearance_only else True,'visibleFilteredRows':len(rows),'queryCombinedWithCategory':None if args.appearance_only else True,
        'clearFiltersResetCategoryAndSearch':None if args.appearance_only else True,'failedRefreshRetainedChannels':None if args.appearance_only else True,'refreshRetryPassed':None if args.appearance_only else True,
        'darkPreferenceSurvivedColdStart':True,'lightPreferenceSurvivedColdStart':True,
        'renderedThemeVerification':'Inspect dark.png and light.png separately.'}
    (args.output/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2));success=True
finally:
    run('shell','cmd','connectivity','set-package-networking-enabled','true',pkg)
    run('shell','cmd','connectivity','set-chain3-enabled','true' if chain=='chain:enabled' else 'false')
    if not success:
        try:screenshot('failure.png')
        except subprocess.CalledProcessError:pass
    run('shell','am','force-stop',pkg)
    root=preferences()
    for n in list(root):
        if n.get('name')=='xm.android.appearance':root.remove(n)
    if original is not None:root.append(original)
    subprocess.run(adb+['shell','-T','run-as',pkg,'dd','of=shared_prefs/defaults.xml'],input=ET.tostring(root,encoding='utf-8',xml_declaration=True),check=True,capture_output=True)
    run('shell','rm','-f','/sdcard/test-owned-radio-browsing.xml')
    run('shell','am','start','-W','-n',pkg+'/xmwatch.android.MainActivity')
