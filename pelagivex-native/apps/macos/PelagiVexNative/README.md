# PelagiVex Native — macOS development preview

PelagiVex Native is an on-device SwiftUI, AVFoundation, Core ML and Metal instance-segmentation prototype. It runs independently of the existing Java/Web underwater gate detector.

The fixed model is **Ultralytics YOLO11x-seg**, the largest YOLO11 segmentation variant supported by this app's decoder, exported at 768×768 for 80 COCO classes. It is not a claim that this is the best model for every scene. Core ML is allowed to use all available compute units (CPU, GPU and Neural Engine); macOS decides how to schedule operations. The larger model may be slower and use more memory than the earlier YOLO11n-seg preview.

## Run

On this Mac, open `~/Applications/PelagiVex.app`, or run:

```bash
open "$HOME/Applications/PelagiVex.app"
```

Wait for the model to load, then click **Start Camera** and grant access if prompted. Frames stay on the device and are not saved by default. The app uses an ad-hoc local signature and is not notarized.

## Set up and build

Requires Apple Silicon, macOS 14+, Python 3.11 or 3.12, and Xcode Command Line Tools. Read the [Ultralytics model license](https://www.ultralytics.com/license) before downloading. The setup downloads dependencies and model weights to an isolated local environment and exports the model. It does not overwrite an existing model directory.

```bash
PYTHON=python3.12 bash scripts/setup_model.sh --acknowledge-model-license
bash scripts/build.sh
open dist/PelagiVex.app
```

The build normally runs `swift test`. Some Command Line Tools installations lack XCTest; use full Xcode for tests. To build a local app without running Swift tests, explicitly run `bash scripts/build.sh --skip-tests`. If `coremlcompiler` is unavailable, the app compiles the bundled model when loading. Without the model, the app runs as camera preview only.

## Verification and limitations

```bash
swift test
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

The exporter checks tensor shapes and compares Core ML and PyTorch outputs on two synthetic inputs. This is not an accuracy benchmark or a substitute for real camera tests. The model recognizes 80 pretrained classes, not arbitrary objects or underwater gates. Masks are reconstructed at prototype resolution, and fine edges may be coarse. Long-duration operation, thermal performance, camera color and geometry, and accuracy across scenes require further testing. The FPS and callback-to-GPU P95 shown in the app are measurements, not guarantees or full physical display latency.

## Approximate depth

The object list shows a color matching each mask and an uncalibrated estimate of forward depth, not a measured straight-line distance. The existing Depth Anything V2 Metric Indoor Base model runs locally in a separate Python worker using the project root `.venv-model` and `model/local-depth/`. Its weights are CC BY-NC 4.0. The estimate takes the median over valid depth pixels inside the instance mask, with a small interior erosion when possible, to reduce background contamination. Inaccurate masks, occlusion, motion and scene conditions can still cause large errors; no improvement in real-world accuracy is claimed without measured reference distances. Depth updates are slower than video, may lag, and expire after five seconds. This Mac has a local copy of the depth environment and weights under `~/Library/Application Support/PelagiVex`. If it is missing, the development build falls back to the project root.

## Cameras

The Camera menu lists devices recognized by macOS. Automatic mode selects an external camera and does not fall back to the built-in camera. Stop the camera before changing the selection. A phone must first expose a macOS-compatible webcam; an ordinary phone connection alone does not provide a camera stream. Camera authorization is controlled by macOS and a locally ad-hoc-signed rebuild can request access again.
