#!/bin/bash
# Compile the real sign-in views against Apple SDK SwiftUI. A service stub keeps
# this API-availability check independent of provider dependencies and sessions.
set -euo pipefail
xm_auth_repo="$(cd "$(dirname "$0")/.." && pwd)"
xm_auth_output="$xm_auth_repo/build/apple-auth-parity"
mkdir -p "$xm_auth_output"
cat > "$xm_auth_output/ServiceStub.swift" <<'SWIFT'
import Foundation
import Observation
@Observable @MainActor final class XMRadioService {
    var errorMessage: String?
    var debugLog = ""
    func signIn(username: String, password: String) async -> Bool { false }
}
SWIFT
xcrun swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios17.0-simulator -module-cache-path "$xm_auth_output/ios-module-cache" \
    "$xm_auth_repo/XMWatch-iOS/Features/Auth/SignInView.swift" "$xm_auth_output/ServiceStub.swift" \
    > "$xm_auth_output/ios-typecheck.log" 2>&1
xcrun swiftc -typecheck -sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    -target arm64-apple-watchos10.0-simulator -module-cache-path "$xm_auth_output/watch-module-cache" \
    "$xm_auth_repo/XMWatch-watchOS/Features/Auth/XMSignInView.swift" "$xm_auth_output/ServiceStub.swift" \
    > "$xm_auth_output/watch-typecheck.log" 2>&1
printf '%s\n' 'PASS: real iOS/watchOS auth views type-check against simulator SwiftUI; provider service is stubbed.'
