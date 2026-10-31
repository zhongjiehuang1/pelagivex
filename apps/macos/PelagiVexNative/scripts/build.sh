#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Building the app requires macOS and Xcode Command Line Tools.' >&2; exit 1; }
xcrun --find swift >/dev/null
swift test
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
mkdir -p dist
STAGE="$(mktemp -d "$PWD/dist/.app-build.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
APP="$STAGE/PelagiVex.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PelagiVexNative" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Model/model.json && -d Model/UniversalSeg.mlpackage ]]; then
  mkdir -p "$APP/Contents/Resources/Model"
  cp Model/model.json "$APP/Contents/Resources/Model/"
  cp Model/export-report.json "$APP/Contents/Resources/Model/" 2>/dev/null || true
  xcrun coremlcompiler compile Model/UniversalSeg.mlpackage "$APP/Contents/Resources/Model"
else
  echo 'NOTICE: Building camera-preview app without weights. Use Choose model folder to enable segmentation.' >&2
fi
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# Ad-hoc, local-development signing only. This is NOT Developer ID signing or notarization.
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
if [[ -d dist/PelagiVex.app ]]; then
  mv dist/PelagiVex.app "dist/PelagiVex.previous.$(date +%Y%m%d%H%M%S).app"
fi
mv "$APP" dist/PelagiVex.app
printf '\nBuilt: %s/dist/PelagiVex.app\n' "$PWD"
