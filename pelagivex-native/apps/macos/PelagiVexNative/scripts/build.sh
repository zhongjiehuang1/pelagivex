#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Building the app requires macOS and Xcode Command Line Tools.' >&2; exit 1; }
xcrun --find swift >/dev/null
if [[ "${1:-}" == --skip-tests ]]; then
  echo 'NOTICE: Swift tests skipped; this build has not passed the test suite.' >&2
elif [[ $# -eq 0 ]]; then
  swift test
else
  echo 'Usage: bash scripts/build.sh [--skip-tests]' >&2
  exit 2
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
mkdir -p dist
STAGE="$(mktemp -d "$PWD/dist/.app-build.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
APP="$STAGE/PelagiVex.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PelagiVexNative" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/PelagiVex.icns "$APP/Contents/Resources/"
cp scripts/depth_worker.py "$APP/Contents/Resources/"
cp scripts/mask_depth.py "$APP/Contents/Resources/"
MODEL_DIR="Model-YOLO11x-seg-768"
if [[ -f "$MODEL_DIR/model.json" && -d "$MODEL_DIR/UniversalSeg.mlpackage" ]]; then
  mkdir -p "$APP/Contents/Resources/Model"
  cp "$MODEL_DIR/model.json" "$APP/Contents/Resources/Model/"
  cp "$MODEL_DIR/export-report.json" "$APP/Contents/Resources/Model/" 2>/dev/null || true
  if xcrun --find coremlcompiler >/dev/null 2>&1; then
    xcrun coremlcompiler compile "$MODEL_DIR/UniversalSeg.mlpackage" "$APP/Contents/Resources/Model"
  else
    echo 'NOTICE: coremlcompiler unavailable; app will compile the model when loading.' >&2
    cp -R "$MODEL_DIR/UniversalSeg.mlpackage" "$APP/Contents/Resources/Model/"
  fi
else
  echo 'NOTICE: Building camera-preview app without YOLO11x-seg. Run scripts/setup_model.sh to install it.' >&2
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
