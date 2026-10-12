#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/app"
APP_DIR="$ROOT_DIR/.build/Stillmatter.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_IDENTIFIER="works.stillmatter.Stillmatter"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_LEGAL_FILES="${REQUIRE_LEGAL_FILES:-0}"

case "$REQUIRE_LEGAL_FILES" in
  0|1) ;;
  *) printf 'REQUIRE_LEGAL_FILES must be 0 or 1.\n' >&2; exit 1 ;;
esac

missing_legal_files=()
for legal_file in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$ROOT_DIR/$legal_file" ]] || missing_legal_files+=("$legal_file")
done
if (( ${#missing_legal_files[@]} > 0 )); then
  if [[ "$REQUIRE_LEGAL_FILES" == 1 ]]; then
    printf 'Cannot package app: missing required legal file(s): %s\n' "${missing_legal_files[*]}" >&2
    exit 1
  fi
  printf 'WARNING: missing legal file(s): %s. Local development build only; do not distribute this bundle.\n' "${missing_legal_files[*]}" >&2
fi
if [[ -f "$ROOT_DIR/THIRD_PARTY_NOTICES.md" ]] && grep -q '^ATTRIBUTION_REVIEW_REQUIRED$' "$ROOT_DIR/THIRD_PARTY_NOTICES.md"; then
  if [[ "$REQUIRE_LEGAL_FILES" == 1 ]]; then
    printf 'Cannot package app: THIRD_PARTY_NOTICES.md has unresolved upstream attribution.\n' >&2
    exit 1
  fi
  printf 'WARNING: third-party attribution is incomplete. Local development build only; do not distribute this bundle.\n' >&2
fi

rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

swift build --package-path "$ROOT_DIR" --configuration release --product Stillmatter
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --configuration release --show-bin-path)"
cp "$BIN_DIR/Stillmatter" "$MACOS_DIR/Stillmatter"

cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
for legal_file in LICENSE THIRD_PARTY_NOTICES.md; do
  if [[ -f "$ROOT_DIR/$legal_file" ]]; then
    cp "$ROOT_DIR/$legal_file" "$RESOURCES_DIR/$legal_file"
  fi
done

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Stillmatter</string>
  <key>CFBundleIdentifier</key>
  <string>works.stillmatter.Stillmatter</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Stillmatter</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 Nazar Topolnytskyi</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Stillmatter uses the microphone to record meetings when you start or approve meeting capture.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Stillmatter records system audio during meeting capture without retaining screen video.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Stillmatter reads calendar events to add meeting context to Today’s meeting context.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  # A fixed designated requirement gives local rebuilds a stable TCC identity. Without it,
  # Screen Recording permission is forgotten whenever the executable changes.
  codesign \
    --force \
    --sign - \
    --identifier "$BUNDLE_IDENTIFIER" \
    --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
    "$APP_DIR"
else
  codesign \
    --force \
    --sign "$CODE_SIGN_IDENTITY" \
    --identifier "$BUNDLE_IDENTIFIER" \
    "$APP_DIR"
fi

printf 'Built %s\n' "$APP_DIR"
