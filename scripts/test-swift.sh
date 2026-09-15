#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if [ "$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsAutomaticTermination' app/Info.plist)" != true ]; then
  echo "app/Info.plist must enable automatic termination support before Vox opts out" >&2
  exit 1
fi

mkdir -p .build/swift-tests
swiftc \
  Sources/Vox/ApplicationLifecycle.swift \
  Sources/Vox/AudioRecorder.swift \
  Sources/Vox/Models.swift \
  Sources/Vox/HotkeyManager.swift \
  Sources/Vox/SettingsStore.swift \
  Tests/SwiftBehaviorTests/main.swift \
  -o .build/swift-tests/run
.build/swift-tests/run
