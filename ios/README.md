# CFData-WEB iOS TrollStore Package

This directory contains the iOS WebView shell used to build `cfdata-ios-arm64.tipa`.

## Important

- The package is intended for TrollStore, not normal App Store sideloading.
- It uses `posix_spawn` to run the bundled Go backend from the app data directory.
- The TrollStore-specific entitlements make the app unsandboxed and allow child
  process creation. These entitlements are preserved when TrollStore re-signs
  the package on install.
- Supported TrollStore devices are iOS 14.0 through 16.6.1, 16.7 RC, and
  17.0 on compatible hardware. Check TrollStore's current compatibility guide
  before installing.

## Local Build

Building the `.ipa`/`.tipa` requires macOS, Xcode, Go, XcodeGen, and ldid:

```bash
brew install xcodegen ldid
./ios/build.sh
```

The output is written to `ios/cfdata-ios-arm64.ipa` and
`ios/cfdata-ios-arm64.tipa`. The GitHub Actions workflow builds the same files.
