---
name: ios-build
description: Build the iOS app for the simulator. Use before running tests, or to check for compile errors after edits.
---

# Build the app

If `App.xcworkspace` exists:
```bash
xcodebuild \
  -workspace App/App.xcworkspace \
  -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath "$PWD/.build/DerivedData" \
  build 2>&1 | xcbeautify
```

Otherwise use `-project App/App.xcodeproj`.

For a single Swift Package (faster, cheaper):
```bash
cd Packages/<ModuleName>
swift build
```

# Per-worktree builds
When running inside a git worktree, always set `-derivedDataPath "$PWD/.build/DerivedData"` so parallel builds in different worktrees do not corrupt shared derived data.

# Common errors
- `tool 'xcodebuild' requires Xcode` - xcode-select points at Command Line Tools. Tell the user to run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once. Do not attempt sudo yourself.
- `Scheme App is not currently configured` - the user needs to share the scheme in Xcode (Product -> Scheme -> Manage Schemes, check "Shared").
