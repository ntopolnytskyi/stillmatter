#!/usr/bin/env bash
# Optimized native validation, never the distributable app. Keep compiler flags
# and products in a separate SwiftPM scratch directory to avoid release pollution.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$ROOT_DIR/.build/Stillmatter.app"
BUILD_DIR="$ROOT_DIR/.build/native-probes"
APP_DIR="$BUILD_DIR/StillmatterNativeProbes.app"
IDENTIFIER="works.stillmatter.Stillmatter.NativeProbes"

if [[ ! -x "$SCAFFOLD/Contents/MacOS/Stillmatter" ]]; then
  printf 'First run: bash scripts/build-app.sh\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$SCAFFOLD"
swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR" \
  --configuration release --product Stillmatter -Xswiftc -DSTILLMATTER_NATIVE_PROBES
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR" \
  --configuration release --show-bin-path)"

# Delete only this helper's generated bundle; leave the shipping app untouched.
rm -rf "$APP_DIR"
cp -R "$SCAFFOLD" "$APP_DIR"
cp "$BIN_DIR/Stillmatter" "$APP_DIR/Contents/MacOS/Stillmatter"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $IDENTIFIER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Stillmatter Native Probes' "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier "$IDENTIFIER" \
  --requirements "=designated => identifier \"$IDENTIFIER\"" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'Native-probe app (not for distribution): %s\n' "$APP_DIR"
