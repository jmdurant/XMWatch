#!/usr/bin/env python3
"""Verify an APK's signature, packaging, and every bundled native library.

Uses Android build-tools and NDK llvm-readelf. Reports static 16 KiB alignment;
runtime behavior is covered separately by the device playback harnesses.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=pathlib.Path)
    parser.add_argument("--release", action="store_true", help="Require a non-debuggable manifest")
    parser.add_argument("--abi", help="Require exactly this native ABI")
    args = parser.parse_args()
    sdk = pathlib.Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", "")))
    versions = sorted((sdk / "build-tools").glob("*"), key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)))
    if not versions: raise RuntimeError("Set ANDROID_HOME to an Android SDK with build-tools installed.")
    build_tools = versions[-1]
    ndk = os.environ.get("XMWATCH_ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK_HOME")
    roots = [pathlib.Path(ndk)] if ndk else sorted((sdk / "ndk").glob("*"), key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)), reverse=True)
    readers = [p for root in roots for p in root.glob("toolchains/llvm/prebuilt/*/bin/llvm-readelf")]
    if not readers: raise RuntimeError("Install an Android NDK or set XMWATCH_ANDROID_NDK_HOME.")

    def run(*command):
        result = subprocess.run([str(c) for c in command], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(f"{pathlib.Path(str(command[0])).name} failed: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout

    apk = args.apk.resolve(strict=True)
    signature = run(build_tools / "apksigner", "verify", "--verbose", "--print-certs", apk)
    run(build_tools / "zipalign", "-c", "-P", "16", "4", apk)
    metadata = run(build_tools / "aapt", "dump", "badging", apk)
    package = re.search(r"package: name='([^']+)'", metadata)
    minimum = re.search(r"sdkVersion:'(\d+)'", metadata)
    target = re.search(r"targetSdkVersion:'(\d+)'", metadata)
    if not package or not minimum or not target: raise RuntimeError("Missing APK manifest metadata.")
    debuggable = "application-debuggable" in metadata
    if args.release and debuggable: raise RuntimeError("The requested release APK is debuggable.")
    abis = set()
    checked = []
    with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory(prefix="xmwatch-elf-") as directory:
        bad_entry = archive.testzip()
        if bad_entry: raise RuntimeError(f"Corrupt APK member: {bad_entry}")
        for entry in archive.infolist():
            if not re.fullmatch(r"lib/[^/]+/[^/]+\.so", entry.filename): continue
            abis.add(entry.filename.split("/")[1])
            binary = pathlib.Path(directory) / f"library-{len(checked)}.so"
            with archive.open(entry) as source, binary.open("wb") as destination:
                shutil.copyfileobj(source, destination)
            headers = run(readers[0], "-lW", binary)
            loads = [line.split() for line in headers.splitlines() if line.strip().startswith("LOAD ")]
            if not loads or any(int(line[-1], 16) < 16384 for line in loads):
                raise RuntimeError(f"Native library lacks 16 KiB LOAD alignment: {entry.filename}")
            dynamic = run(readers[0], "-dW", binary)
            hashes = re.findall(r"\((?:GNU_HASH|HASH)\)\s+(0x[0-9a-fA-F]+)", dynamic)
            if not any(int(value, 16) != 0 for value in hashes):
                raise RuntimeError(f"Native library has no usable dynamic symbol hash: {entry.filename}")
            checked.append(entry.filename)
            binary.unlink()
    if not checked: raise RuntimeError("This native app APK contains no shared libraries.")
    if args.abi and abis != {args.abi}: raise RuntimeError(f"Expected ABI {args.abi}; got {sorted(abis)}")
    with apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else None
    if digest is None:
        hasher = hashlib.sha256()
        with apk.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""): hasher.update(chunk)
        digest = hasher.hexdigest()
    print(json.dumps({"apk": str(apk), "package": package.group(1), "min_sdk": int(minimum.group(1)),
        "target_sdk": int(target.group(1)), "debuggable": debuggable, "size_bytes": apk.stat().st_size,
        "abis": sorted(abis), "native_libraries_checked": len(checked), "static_page_alignment": 16384,
        "sha256": digest, "signer_sha256": re.findall(r"certificate SHA-256 digest: ([0-9a-fA-F]+)", signature)}, indent=2))


if __name__ == "__main__":
    try: main()
    except (RuntimeError, OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        raise SystemExit(f"FAIL: {error}")
