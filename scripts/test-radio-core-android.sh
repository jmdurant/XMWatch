#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != --serial || ! "${2:-}" =~ ^emulator-[0-9]+$ ]]; then
    echo 'Usage: bash scripts/test-radio-core-android.sh --serial emulator-5560' >&2
    exit 2
fi
serial="$2"
repo="$(cd "$(dirname "$0")/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/30.0.16248370}"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
adb="$ANDROID_HOME/platform-tools/adb"
[[ "$("$adb" -s "$serial" shell getprop ro.product.cpu.abi | tr -d '\r')" == arm64-v8a ]] || {
    echo 'An ARM64 Android emulator is required.' >&2; exit 1;
}
version="${XMWATCH_SWIFT_ANDROID_VERSION:-6.4.1}"
sdk_home="${XMWATCH_SWIFT_SDK_HOME:-$HOME/.swiftpm/swift-sdks}"
sdk="$sdk_home/swift-$version-RELEASE_android.artifactbundle/swift-android"
build_args=(--package-path "$repo/XMRadioCore" --scratch-path "$repo/XMRadioCore/.build/android"
    --swift-sdks-path "$sdk_home" --swift-sdk "swift-$version-RELEASE_android"
    --triple aarch64-unknown-linux-android28 --jobs 2)
swiftly run swift build "${build_args[@]}" --build-tests "+$version"
products="$(swiftly run swift build "${build_args[@]}" --show-bin-path "+$version")"
remote="/data/local/tmp/xmwatch-radio-tests-$$"
"$adb" -s "$serial" shell mkdir -p "$remote"
trap '''"$adb" -s "$serial" shell rm -rf "$remote" >/dev/null 2>&1 || true''' EXIT
"$adb" -s "$serial" push "$products"/*-test-runner "$products"/*.so "$remote/" >/dev/null
"$adb" -s "$serial" push "$sdk/swift-resources/usr/lib/swift-aarch64/android/"*.so "$remote/" >/dev/null
"$adb" -s "$serial" push "$sdk/ndk-sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$remote/" >/dev/null
"$adb" -s "$serial" shell chmod 700 "$remote"/*-test-runner
mkdir -p "$repo/build/android/evidence"
for executable in "$products"/*-test-runner; do
    runner="$(basename "$executable")"
    log="$repo/build/android/evidence/$runner.log"
    "$adb" -s "$serial" shell "LD_LIBRARY_PATH=$remote $remote/$runner --testing-library swift-testing" 2>&1 | tee "$log"
    if ! grep -Eq "Test run with [1-9][0-9]* tests.*passed" "$log"; then
        echo "Native test runner did not report a nonempty passing suite." >&2
        exit 1
    fi
done
