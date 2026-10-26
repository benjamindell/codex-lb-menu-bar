#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
swiftc StatusBarLogic.swift DropdownPlacement.swift CredentialStore.swift StatusBarLogicTests.swift -framework Security -o build/StatusBarLogicTests
./build/StatusBarLogicTests
swiftc -parse-as-library ResetCredits.swift ResetCreditsTests.swift -o build/ResetCreditsTests
./build/ResetCreditsTests
swiftc -D TESTING -parse-as-library -target arm64-apple-macosx13.0 -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework Security \
  StatusBarLogic.swift CredentialStore.swift DropdownPlacement.swift ResetCredits.swift ResetCreditPicker.swift \
  PanelStyle.swift MenuPanel.swift CodexLBMenuBar.swift AccountActionsTests.swift -o build/AccountActionsTests
./build/AccountActionsTests
