#!/bin/bash
# Standalone platform-only probe, with its own package and instrumentation process.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/android-environment.sh"
"$repo/xmwatch-android/Android/gradlew" -p "$repo/scripts/android-controller-probe" :app:assembleDebug --no-daemon --console=plain \
    "-Dorg.gradle.jvmargs=-Xmx768m"
printf '%s\n' "$repo/scripts/android-controller-probe/app/build/outputs/apk/debug/app-debug.apk"
