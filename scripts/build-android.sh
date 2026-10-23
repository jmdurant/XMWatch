#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
python3 "$repo/scripts/prepare-android-dependencies.py"
export SKIP_COMMAND_OVERRIDE="$repo/scripts/skip-android-toolchain.sh"
export SKIP_EXPORT_DEBUG_INFO=line-tables
# The Gradle plugin may continue after a failed Swift pre-build and package stale
# generated sources. Run the same compiler/transpiler explicitly and fail closed.
android_preflight_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --triple arm64-apple-ios --sdk "$android_preflight_sdk" \
    --package-path "$repo/xmwatch-android" --jobs 2
mode=debug
if [[ "${1:-}" == --release ]]; then mode=release; shift; fi
output="${XMWATCH_ANDROID_OUTPUT:-$repo/build/android}"
mkdir -p "$output/tmp"
output="$(cd "$output" && pwd -P)"
export TMPDIR="$output/tmp/"
if [[ "$mode" == release ]]; then
    "$repo/xmwatch-android/Android/gradlew" -p "$repo/xmwatch-android/Android" :app:assembleRelease :app:bundleRelease --console=plain \
        "-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=1g" "$@"
    products="$repo/xmwatch-android/.build/Android/app/outputs"
    cp "$products/apk/release/app-release.apk" "$output/XMWatchAndroid-release.apk"
    cp "$products/bundle/release/app-release.aab" "$output/XMWatchAndroid-release.aab"
    mkdir -p "$output/release-symbols"
    cp "$products/mapping/release/mapping.txt" "$output/release-symbols/mapping.txt"
    python3 "$repo/scripts/verify-android-apk.py" "$output/XMWatchAndroid-release.apk" --release --abi arm64-v8a > "$output/release-verification.json"
    echo "APK: $output/XMWatchAndroid-release.apk"
    echo "AAB: $output/XMWatchAndroid-release.aab"
else
    "$repo/xmwatch-android/Android/gradlew" -p "$repo/xmwatch-android/Android" :app:assembleDebug --console=plain \
        "-Dorg.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=1g" "$@"
    cp "$repo/xmwatch-android/.build/Android/app/outputs/apk/debug/app-debug.apk" "$output/XMWatchAndroid-debug.apk"
    echo "APK: $output/XMWatchAndroid-debug.apk"
fi
