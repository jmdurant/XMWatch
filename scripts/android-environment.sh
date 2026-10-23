#!/bin/bash
# Shared, process-local toolchain selection. Source this from Android commands.
# Do not change the user's global Java, Swift, or SDK configuration.
xmwatch_is_jdk21() {
    [[ -x "$1/bin/java" && -r "$1/release" ]] || return 1
    case "$(<"$1/release")" in
        *'JAVA_VERSION="21.'*|*'JAVA_VERSION="21"'*|*'JAVA_VERSION="21-'*) return 0 ;;
        *) return 1 ;;
    esac
}

xmwatch_jdk="${XMWATCH_JAVA_HOME:-${JAVA_HOME:-}}"
if [[ -z "${XMWATCH_JAVA_HOME:-}" ]] && ! xmwatch_is_jdk21 "$xmwatch_jdk"; then
    for candidate in /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
                     /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home; do
        if xmwatch_is_jdk21 "$candidate"; then xmwatch_jdk="$candidate"; break; fi
    done
fi
if ! xmwatch_is_jdk21 "$xmwatch_jdk"; then
    echo 'Install JDK 21 and set XMWATCH_JAVA_HOME or JAVA_HOME to its Home directory.' >&2
    return 1 2>/dev/null || exit 1
fi
export JAVA_HOME="$xmwatch_jdk"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_NDK_HOME="${XMWATCH_ANDROID_NDK_HOME:-${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/30.0.16248370}}"
if [[ ! -f "$ANDROID_NDK_HOME/source.properties" || ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]]; then
    echo 'Install Android NDK r30 (30.0.16248370), or set XMWATCH_ANDROID_NDK_HOME to its directory.' >&2
    return 1 2>/dev/null || exit 1
fi
# Swift Build resolves nonstandard SDK installations through NDK_ROOT.
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
unset xmwatch_jdk candidate
unset -f xmwatch_is_jdk21
