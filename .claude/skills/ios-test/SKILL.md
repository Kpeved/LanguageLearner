---
name: ios-test
description: Run iOS unit tests on simulator. Use after building, or when verifying behavior change.
---

# Run all tests via the app scheme
```bash
xcodebuild \
  -workspace App/App.xcworkspace \
  -scheme App \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath "$PWD/.build/DerivedData" \
  test 2>&1 | xcbeautify
```

# Run tests for one Swift Package (preferred, cheap)
```bash
cd Packages/<ModuleName>
swift test
```

Use this whenever possible - `swift test` is faster, does not require a simulator, and produces cleaner output. Fall back to `xcodebuild test` only for modules that depend on UIKit/SwiftUI or the app target.

# Boot the simulator (only if needed)
```bash
xcrun simctl boot "iPhone 15" 2>/dev/null || true
```

# Filtering output
For machine-parseable output add `-resultBundlePath out.xcresult` then read it. For human-readable, the `| xcbeautify` pipe is enough.
