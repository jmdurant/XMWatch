#!/usr/bin/env python3
"""Run a command with durable escrow and verified restoration of XMWatch private state."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import signal
import subprocess
import sys
import tempfile


PACKAGE = "com.doctordurant.xmwatch.android"
EXPECTED_AVD = os.environ.get("RADIO_TEST_AVD", "CadenceCarLibrary")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not re.fullmatch(r"emulator-\d+", args.serial):
        parser.error("--serial must identify an emulator")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("supply a command after --")
    root = Path(__file__).resolve().parents[1]
    sdk = Path(os.environ.get("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools"))
    adb = [str(sdk / "platform-tools/adb"), "-s", args.serial]

    def run(*argv, **kwargs):
        return subprocess.run(adb + list(argv), check=True, capture_output=True, timeout=30, **kwargs)

    def private(*argv, **kwargs):
        # adb shell reconstructs a remote command line; quote every argument there too.
        return run("shell", "-T", shlex.join(["run-as", PACKAGE, *argv]), **kwargs)

    def exists(path, kind="-f"):
        result = subprocess.run(adb + ["shell", "-T", shlex.join(["run-as", PACKAGE, "test", kind, path])],
                                capture_output=True, timeout=30)
        if result.returncode not in (0, 1) or result.stdout or result.stderr:
            raise RuntimeError("Private path presence check failed")
        return result.returncode == 0

    def read(path):
        return private("cat", path).stdout if exists(path) else None

    def preferences():
        if not exists("shared_prefs", "-d"):
            return set()
        result = private("find", "shared_prefs", "-type", "f", "-print0")
        if result.stderr or (result.stdout and not result.stdout.endswith(b"\0")):
            raise RuntimeError("Private preference listing failed")
        paths = set()
        for raw in result.stdout.split(b"\0")[:-1]:
            path = raw.decode("utf-8")
            parts = PurePosixPath(path).parts
            if len(parts) < 2 or parts[0] != "shared_prefs" or any(p in (".", "..") for p in path.split("/")):
                raise RuntimeError("Unexpected private preference path")
            paths.add(path)
        return paths

    def fsync_directory(path):
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    actual_avd = run("emu", "avd", "name").stdout.decode().splitlines()[0].strip()
    if actual_avd != EXPECTED_AVD:
        raise RuntimeError("Emulator AVD mismatch; select RADIO_TEST_AVD explicitly for another test AVD")
    private("id")  # Require an already installed, debuggable app before touching state.
    run("shell", "am", "force-stop", PACKAGE)
    paths = preferences()
    for path in list(paths):
        base = path
        while base.endswith((".bak", ".new")):
            base = base[:-4]
        paths.update(base + suffix for suffix in ("", ".bak", ".new"))
    paths.update(f"shared_prefs/{name}.xml{suffix}"
                 for name in ("radio-session", "radio-region-US", "radio-region-CA", "defaults")
                 for suffix in ("", ".bak", ".new"))
    backup = {path: read(path) for path in sorted(paths)}

    folder = root / ".build/android-private-backups"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(folder, 0o700)
    descriptor, name = tempfile.mkstemp(prefix="radio-native-", suffix=".json", dir=folder)
    escrow = Path(name)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump({"version": 1, "package": PACKAGE, "serial": args.serial, "avd": EXPECTED_AVD,
                   "files": {path: base64.b64encode(data).decode("ascii") if data is not None else None
                             for path, data in backup.items()}}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    fsync_directory(folder)

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    previous_term = signal.signal(signal.SIGTERM, interrupted)
    previous_int = signal.getsignal(signal.SIGINT)
    result = 1
    child = None
    try:
        child = subprocess.Popen(command)
        try:
            result = child.wait()
        except KeyboardInterrupt:
            # A protected command can temporarily install a non-debuggable APK.
            # Let its finally restore the original debug APK before run-as below.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
            try:
                child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                raise RuntimeError("Protected command did not finish its cleanup; retain durable escrow and wait for recovery")
            raise
    finally:
        # Finish restoration even if another interrupt arrives during cleanup.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            if child is not None and child.poll() is None:
                raise RuntimeError("Protected command is still running; private restoration deferred to preserve durable escrow")
            run("shell", "am", "force-stop", PACKAGE)
            created = preferences() - backup.keys()
            for path in sorted(created):
                private("rm", "-f", path)
            for path, data in backup.items():
                if data is None:
                    private("rm", "-f", path)
                else:
                    private("mkdir", "-p", str(PurePosixPath(path).parent))
                    private("dd", "of=" + path, input=data)
            rows = []
            for path in sorted(backup.keys() | created):
                before = backup.get(path)
                after = read(path)
                if before != after:
                    raise RuntimeError("Private file restoration mismatch")
                rows.append({"path": path, "existedBefore": before is not None, "existsAfter": after is not None,
                             "beforeSHA256": hashlib.sha256(before).hexdigest() if before is not None else None,
                             "afterSHA256": hashlib.sha256(after).hexdigest() if after is not None else None})
            expected_preferences = {path for path, data in backup.items()
                                    if path.startswith("shared_prefs/") and data is not None}
            if preferences() != expected_preferences:
                raise RuntimeError("Private preference inventory restoration mismatch")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            report = {"privateFilePresenceAndBytesRestored": True,
                      "privateBackupEscrowRemoved": False, "privateFileRestoration": rows}

            def write_report():
                with args.output.open("w") as stream:
                    json.dump(report, stream, indent=2)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())

            write_report()
            escrow.unlink()
            fsync_directory(folder)
            report["privateBackupEscrowRemoved"] = True
            write_report()
        except BaseException:
            if escrow.exists():
                print(f"Restoration did not complete; durable private escrow retained at {escrow}", file=sys.stderr)
            else:
                print("State was verified and escrow removed, but recording the final result failed", file=sys.stderr)
            raise
        finally:
            signal.signal(signal.SIGTERM, previous_term)
            signal.signal(signal.SIGINT, previous_int)
    return result if result >= 0 else 128 - result


if __name__ == "__main__":
    raise SystemExit(main())
