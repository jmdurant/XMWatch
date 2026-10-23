#!/bin/bash
set -euo pipefail

# Skip invokes this hook for its native Swift build. Resolve the SDK directory so
# installations moved onto another volume work as well as ordinary ~/.swiftpm installs.
skip_command="${XMWATCH_SKIP_COMMAND:-$(command -v skip)}"
# Homebrew's launcher clears xattrs each time, which SwiftPM's plugin sandbox
# correctly forbids. Invoke the installed executable directly inside that sandbox.
skip_entry="$(realpath "$skip_command")"
skip_binary="$(dirname "$skip_entry")/../macos/skip"
if [[ -x "$skip_binary" ]]; then skip_command="$skip_binary"; fi
if [[ "${1:-}" == android && "${2:-}" == build ]]; then
    shift 2
    repo="$(cd "$(dirname "$0")/.." && pwd)"
    source "$repo/scripts/android-environment.sh"
    sdk_home="${XMWATCH_SWIFT_SDK_HOME:-$HOME/.swiftpm/swift-sdks}"
    sdk_home="$(cd "$sdk_home" && pwd -P)"
    export XMWATCH_SWIFT_SDK_HOME="$sdk_home"
    sdk_version="${XMWATCH_SWIFT_ANDROID_VERSION:-6.4.1}"
    case "${XMWATCH_ANDROID_ARCH:-aarch64}" in
        aarch64|x86_64|armv7) triple="${XMWATCH_ANDROID_ARCH:-aarch64}-unknown-linux-android28" ;;
        *) echo 'Choose aarch64, x86_64, or armv7 for XMWATCH_ANDROID_ARCH.' >&2; exit 1 ;;
    esac
    export XMWATCH_ANDROID_TRIPLE="$triple"
    export XMWATCH_SWIFT_COMMAND="$(swiftly run sh -c 'command -v swift' "+$sdk_version")"
    real_toolchain="$(dirname "$(dirname "$(dirname "$XMWATCH_SWIFT_COMMAND")")")"
    proxy="$repo/.build/android-toolchain/$sdk_version.xctoolchain"
    mkdir -p "$proxy/usr/bin"
    # A project-local launcher handles Skip's helper queries without changing the
    # installed compiler or hiding other SDKs. Existing links are immutable; two
    # Gradle build graphs may enter this hook concurrently.
    for entry in "$real_toolchain"/*; do
        name="$(basename "$entry")"
        if [[ "$name" != usr && ! -e "$proxy/$name" ]]; then
            ln -s "$entry" "$proxy/$name" 2>/dev/null || test -L "$proxy/$name"
        fi
    done
    for entry in "$real_toolchain/usr"/*; do
        name="$(basename "$entry")"
        if [[ "$name" != bin && ! -e "$proxy/usr/$name" ]]; then
            ln -s "$entry" "$proxy/usr/$name" 2>/dev/null || test -L "$proxy/usr/$name"
        fi
    done
    for entry in "$real_toolchain/usr/bin"/*; do
        name="$(basename "$entry")"
        if [[ "$name" == swift ]]; then entry="$repo/scripts/swift-android.sh"; fi
        if [[ ! -e "$proxy/usr/bin/$name" ]]; then
            ln -s "$entry" "$proxy/usr/bin/$name" 2>/dev/null || test -L "$proxy/usr/bin/$name"
        fi
    done
    args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --arch ]]; then shift 2
        else args+=("$1"); shift
        fi
    done
    exec "$skip_command" android build \
        --swift-version "$sdk_version" --swift-sdk-home "$sdk_home" --toolchain "$proxy" \
        --arch "${XMWATCH_ANDROID_ARCH:-aarch64}" "${args[@]}" --jobs "${XMWATCH_BUILD_JOBS:-2}"
fi
exec "$skip_command" "$@"
