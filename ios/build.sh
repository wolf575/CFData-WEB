#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-1.0.0}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p ios/Resources

CC_WRAPPER="$WORK_DIR/ios-clangwrap.sh"
cat > "$CC_WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
exec "$CLANG" -arch arm64 -isysroot "$SDK_PATH" -mios-version-min=14.0 "$@"
EOF
chmod +x "$CC_WRAPPER"

(
  cd combined_refactor
  GOOS=ios \
  GOARCH=arm64 \
  CGO_ENABLED=1 \
  CC="$CC_WRAPPER" \
  go build -trimpath -ldflags "-s -w -X main.appVersion=$VERSION" \
    -o ../ios/Resources/cfdata .
)

xcodegen generate --spec ios/project.yml

xcodebuild \
  -project ios/CFDataIOS.xcodeproj \
  -scheme CFDataIOS \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  build

APP_PATH="$ROOT_DIR/ios/DerivedData/Build/Products/Release-iphoneos/CFDataIOS.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app bundle was not found: $APP_PATH" >&2
  exit 1
fi

cp "$ROOT_DIR/ios/Resources/cfdata" "$APP_PATH/cfdata"

if [[ ! -f "$APP_PATH/cfdata" ]]; then
  echo "The bundled backend was not copied to $APP_PATH/cfdata" >&2
  exit 1
fi

chmod +x "$APP_PATH/cfdata"
ldid -S"$ROOT_DIR/ios/Support/CFDataIOS.entitlements" "$APP_PATH/CFDataIOS"
ldid -S"$ROOT_DIR/ios/Support/CFDataIOS.entitlements" "$APP_PATH/cfdata"

rm -rf ios/Payload
mkdir -p ios/Payload
cp -R "$APP_PATH" ios/Payload/

rm -f ios/cfdata-ios-arm64.ipa ios/cfdata-ios-arm64.tipa
(
  cd ios
  zip -qry cfdata-ios-arm64.ipa Payload
  cp cfdata-ios-arm64.ipa cfdata-ios-arm64.tipa
)

echo "Built $ROOT_DIR/ios/cfdata-ios-arm64.ipa"
echo "Built $ROOT_DIR/ios/cfdata-ios-arm64.tipa"
