#!/bin/bash
# Runs AdminMover's shell command and quoting against awkward file names (no password needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -swift-version 5 -module-name AdminMoverTests Sources/App/AdminMover.swift \
    Tests/AdminMoverTests/main.swift -o build/tests/adminmover-tests
build/tests/adminmover-tests
