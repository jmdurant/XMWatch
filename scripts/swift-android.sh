#!/bin/bash
set -euo pipefail
xmwatch_repo="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
source "$xmwatch_repo/scripts/android-environment.sh"
# Skip 1.9.16 forwards custom SDK arguments to compilation, but drops them from
# its output-directory query. Apply the same selection to every Swift build call.
case "${1:-}" in
    build|test)
        exec "${XMWATCH_SWIFT_COMMAND:?Missing Swift compiler}" "$@" \
            --swift-sdks-path "${XMWATCH_SWIFT_SDK_HOME:?Missing Swift SDK directory}" \
            --swift-sdk "swift-${XMWATCH_SWIFT_ANDROID_VERSION:-6.4.1}-RELEASE_android" \
            --triple "${XMWATCH_ANDROID_TRIPLE:?Missing Android triple}" ;;
    *) exec "${XMWATCH_SWIFT_COMMAND:?Missing Swift compiler}" "$@" ;;
esac
