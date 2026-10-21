#!/bin/bash
# Compiles the helper's sources (minus its launchd entry point) with the test driver and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/tests
mkdir -p "$OUT"
cat > "$OUT/BuildConfig.swift" <<'EOF'
enum BuildConfig {
    static let appBundleID = "com.example.leftover.tests"
    static let helperLabel = "com.example.leftover.tests.helper"
    static let helperPlistName = "com.example.leftover.tests.helper.plist"
    static let teamID = ""
    static let version = "tests"
}
EOF
HELPER_SOURCES=$(ls Sources/Helper/*.swift | grep -v '/main.swift$')
swiftc -swift-version 5 -module-name HelperTests $HELPER_SOURCES Sources/Shared/*.swift \
    "$OUT/BuildConfig.swift" Tests/HelperTests/main.swift -o "$OUT/helper-tests"
"$OUT/helper-tests"
