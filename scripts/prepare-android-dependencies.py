#!/usr/bin/env python3
"""Apply the reviewed SkipUI 1.64.0 navigation race correction reproducibly.

Upstream: https://github.com/skiptools/skip-ui/issues/572
Do not silently apply this patch to another SDK revision or modified source.
"""
import hashlib,json,subprocess
from pathlib import Path
repo=Path(__file__).resolve().parents[1];package=repo/'xmwatch-android'
source=package/'.build/checkouts/skip-ui/Sources/SkipUI/SkipUI/Containers/Navigation.swift'
if not source.is_file():subprocess.run(['swift','package','resolve','--package-path',str(package)],check=True)
pins=json.loads((package/'Package.resolved').read_text())['pins']
state=next(p['state'] for p in pins if p['identity']=='skip-ui')
assert state=={'revision':'d170d85b9b337b82b630439c633aea2d0eb6ca3e','version':'1.64.0'}, 'Review the navigation patch against the newly resolved SkipUI version.'
original='9eba3deba8702366280cfe4db9230676289305e167616ecbceb5bddcb5546812'
patched='ce0e0e4c3c303cde784ba7b585fa7b8478e219f921331b0ba87c1ff963eb6080'
digest=hashlib.sha256(source.read_bytes()).hexdigest()
if digest==original:
 patch=package/'patches/skip-ui-1.64.0-navigation-state.patch'
 subprocess.run(['git','apply','--check',str(patch)],cwd=package/'.build/checkouts/skip-ui',check=True)
 subprocess.run(['git','apply',str(patch)],cwd=package/'.build/checkouts/skip-ui',check=True)
else:assert digest==patched, 'SkipUI navigation source differs from the reviewed original and patch.'
assert hashlib.sha256(source.read_bytes()).hexdigest()==patched
print('SkipUI 1.64.0 navigation state-race patch verified.')
