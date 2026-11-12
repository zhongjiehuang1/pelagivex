#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Building the app requires macOS and Xcode Command Line Tools.' >&2; exit 1; }
xcrun --find swift >/dev/null
if [[ "${1:-}" == --skip-tests ]]; then
  echo 'NOTICE: Swift tests skipped; this build has not passed the test suite.' >&2
elif [[ $# -eq 0 ]]; then
  bash scripts/test.sh
else
  echo 'Usage: bash scripts/build.sh [--skip-tests]' >&2
  exit 2
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
mkdir -p dist
STAGE="$(mktemp -d "$PWD/dist/.app-build.XXXXXX")"
APP="$STAGE/PelagiVex.app"
CURRENT="$PWD/dist/PelagiVex.app"
REPLACED="$STAGE/replaced.app"
PUBLISH_LOCK="$PWD/dist/.app-publish.lock"
PUBLISH_LOCK_HELD=false

cleanup() {
  local status=$?
  local keep_stage=false
  # A failed or interrupted publish can leave the former app in the staging directory.
  if [[ -d "$REPLACED" && ! -e "$CURRENT" && ! -L "$CURRENT" ]]; then
    if ! mv -- "$REPLACED" "$CURRENT"; then
      printf 'Could not restore the previous app. Recovery copy: %s\n' "$REPLACED" >&2
      keep_stage=true
      status=1
    fi
  elif [[ -d "$REPLACED" && -d "$APP" ]]; then
    printf 'The app destination changed during publishing. Recovery copy: %s\n' "$REPLACED" >&2
    keep_stage=true
    status=1
  fi
  if [[ "$keep_stage" == false ]]; then rm -rf -- "$STAGE" || status=1; fi
  if [[ "$PUBLISH_LOCK_HELD" == true ]]; then rmdir "$PUBLISH_LOCK" || status=1; fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PelagiVexNative" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/PelagiVex.icns "$APP/Contents/Resources/"
cp scripts/depth_worker.py "$APP/Contents/Resources/"
cp scripts/open_vocab_worker.py "$APP/Contents/Resources/"
cp scripts/segmentation_refiner.py "$APP/Contents/Resources/"
cp scripts/mask_depth.py "$APP/Contents/Resources/"
RELATIVE_DEPTH="${PELAGIVEX_RELATIVE_DEPTH_MODEL_DIR:-../../../../.cache/coreml-depth-v2/DepthAnythingV2SmallF16.mlmodelc}"
if [[ -z "${PELAGIVEX_RELATIVE_DEPTH_MODEL_DIR:-}" && ! -d "$RELATIVE_DEPTH" ]]; then
  RELATIVE_DEPTH="${RELATIVE_DEPTH%.mlmodelc}.mlpackage"
fi
case "$RELATIVE_DEPTH" in
  *.mlmodelc|*.mlpackage)
    if [[ -d "$RELATIVE_DEPTH" ]]; then
      cp -R "$RELATIVE_DEPTH" "$APP/Contents/Resources/RelativeDepth.${RELATIVE_DEPTH##*.}"
    else
      echo 'NOTICE: Single-view prediction will use a silhouette when the Core ML relative-depth model is unavailable.' >&2
    fi
    ;;
  *) echo 'Expected PELAGIVEX_RELATIVE_DEPTH_MODEL_DIR to end with .mlmodelc or .mlpackage.' >&2; exit 1 ;;
esac
MODEL_DIR="${PELAGIVEX_MODEL_DIR:-Model-YOLOE26s-PF-640}"
if [[ ! -f "$MODEL_DIR/model.json" && -z "${PELAGIVEX_MODEL_DIR:-}" ]]; then
  MODEL_DIR="Model-YOLO11x-seg-768"
fi
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
  echo 'NOTICE: Building camera-preview app without a segmentation model. Set up or export a verified model first.' >&2
fi
# Keep the historical study's detector and tracker reproducible after changing the live model.
EFFICIENT_DIR="Model-YOLOE26s-PF-640-Mixed"
if [[ -f "$EFFICIENT_DIR/mask-parity-audit-cpu_and_gpu.json" && -d "$EFFICIENT_DIR/UniversalSeg.mlpackage" ]]; then
  mkdir -p "$APP/Contents/Resources/EfficientModel"
  cp "$EFFICIENT_DIR/model.json" "$APP/Contents/Resources/EfficientModel/"
  cp "$EFFICIENT_DIR/export-report.json" "$APP/Contents/Resources/EfficientModel/"
  cp "$EFFICIENT_DIR/mask-parity-audit-cpu_and_gpu.json" "$APP/Contents/Resources/EfficientModel/"
  cp -R "$EFFICIENT_DIR/UniversalSeg.mlpackage" "$APP/Contents/Resources/EfficientModel/"
fi
BASELINE_DIR="Model-YOLO11x-seg-768"
if [[ "$MODEL_DIR" != "$BASELINE_DIR" && -f "$BASELINE_DIR/model.json" && -d "$BASELINE_DIR/UniversalSeg.mlpackage" ]]; then
  mkdir -p "$APP/Contents/Resources/LegacyStudyModel"
  cp "$BASELINE_DIR/model.json" "$APP/Contents/Resources/LegacyStudyModel/"
  cp "$BASELINE_DIR/export-report.json" "$APP/Contents/Resources/LegacyStudyModel/" 2>/dev/null || true
  cp -R "$BASELINE_DIR/UniversalSeg.mlpackage" "$APP/Contents/Resources/LegacyStudyModel/"
fi
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# Ad-hoc, local-development signing only. This is NOT Developer ID signing or notarization.
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
if ! mkdir "$PUBLISH_LOCK"; then
  printf 'Another app publish holds %s. Retry once it is finished.\n' "$PUBLISH_LOCK" >&2
  exit 1
fi
PUBLISH_LOCK_HELD=true
if [[ -e "$CURRENT" || -L "$CURRENT" ]]; then
  if [[ ! -d "$CURRENT" || -L "$CURRENT" ]]; then
    printf 'Unexpected app destination: %s\n' "$CURRENT" >&2
    exit 1
  fi
  mv -- "$CURRENT" "$REPLACED"
fi
mv -- "$APP" "$CURRENT"
printf '\nBuilt: %s\n' "$CURRENT"
