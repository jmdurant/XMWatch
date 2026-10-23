#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
output="$repo/build/android/meta-glasses-harness"
mkdir -p "$output/tmp"
export TMPDIR="$output/tmp/"
"$repo/xmwatch-android/Android/gradlew" -p "$repo/scripts/android-meta-glasses-harness" :app:assembleDebug --no-daemon --console=plain \
    "-Dorg.gradle.jvmargs=-Xmx768m -Djava.io.tmpdir=$output/tmp"
cp "$repo/scripts/android-meta-glasses-harness/app/build/outputs/apk/debug/app-debug.apk" "$output/XMWatchMetaGlassesHarness-debug.apk"
python3 "$repo/scripts/verify-android-meta-glasses-harness.py" "$output/XMWatchMetaGlassesHarness-debug.apk" > "$output/verification.json"
echo "Test instrumentation: $output/XMWatchMetaGlassesHarness-debug.apk"
