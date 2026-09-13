#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
mkdir -p .build/swift-tests
swiftc \
  Sources/Vox/Models.swift \
  Sources/Vox/HotkeyManager.swift \
  Sources/Vox/SettingsStore.swift \
  Tests/SwiftBehaviorTests/main.swift \
  -o .build/swift-tests/run
.build/swift-tests/run
