# PelagiVex Native — 最新版

PelagiVex Native is an on-device general visual-recognition application for everyday scenes and user-specified object categories, built with SwiftUI, AVFoundation, Core ML and Metal.

The C++17 target owns live YOLOE row selection, global tracking assignment, mask label indexing and contour association, scan mask sampling, automatic capture checks and scheduling, and single-view volume and USDZ export. The Objective-C++ depth adapter loads Depth Anything V2 with Core ML. Swift hosts the UI and coordinates the capture, model and rendering APIs. Metal renders the live contours, and RealityKit handles multi-view photogrammetry. SAM and text-guided recognition continue to use the bundled Python worker entry points.

Run the C++ geometry regression below from this directory. The project-root `.cache/single-view-study/cpp-parity/run.sh` compares the release tracker solver and YOLOE decoder against their earlier Swift implementations. `.cache/object-capture-validation/cpp-auto-orbit-parity/run.sh` replays the frame gate comparison. These isolate the changed operations from camera, Core ML, SAM and display latency. [3D workflow and fixture](OBJECT_STUDIO.md)

```bash
c++ -std=c++17 -O2 -Wall -Wextra -Werror -ISources/PelagiVexCpp/include \
  Sources/PelagiVexCpp/SingleViewVolume.cpp Tests/PelagiVexCppTests/SingleViewVolumeTests.cpp \
  -o /tmp/pelagivex-single-view-volume-tests
/tmp/pelagivex-single-view-volume-tests
```

**Fast objects** defaults to **YOLOE-26s prompt-free segmentation**, exported at 640×640 with its 4,585-name vocabulary. It automatically produces labels, confidence and instance masks without typed queries. The vocabulary includes scene and attribute terms and can produce false labels. The old YOLO11x 80-category model remains a study baseline. **Text-guided objects** retains local OWLv2 plus SAM2.1 for custom English queries.

## Automatic recognition and detailed contours

The automatic model is no longer restricted to 80 classes or underwater imagery. **Live fine contours (SAM)** is enabled by default. SAM2.1 Tiny runs in a separate queue with one request in flight and no backlog; new YOLO detections and display frames continue independently. Disable it to retain only the segmenter's native contours. Fine mask maps have a maximum 1,024-pixel long side. **Outline width** controls the stroke from 1–4 pixels. Refined visualization masks do not replace the prototype masks used by depth measurements.

Metal propagates a recent SAM contour into the current detection box only for a unique, confirmed track ID with the same class. The source must be at most 0.65 seconds old, box IoU must be at least 0.45, and width/height ratios must each remain within 0.7–1.4. Source coordinates remove model letterboxing; large image-aspect changes are rejected. Invalid or expired objects use the current native mask, and missing objects leave no old contour behind. SAM textures are uploaded once per result sequence. Mode changes, disabling SAM and stopping the camera clear cached results.

This box-based affine approximation does not estimate optical flow and cannot guarantee correct contours under deformation, rotation, occlusion or an incorrect track association. The UI separately reports **Inference / Display FPS** and **SAM refresh FPS / Worker / Result age / Fine n/m targets**. A 30 FPS display is not 30 SAM inferences per second; `Fine n/m` counts only currently eligible contour associations.

Choose **Text-guided objects**, enter English object names separated by commas under **Custom categories**, then click **Apply text categories**. Examples: `computer monitor, cabinet, headphones, keys, pen, tissue box`. SAM2.1 turns its detections into contours on the analyzed frame. A/B depth remains available in **Fast objects**. Mode and vocabulary changes clear old tracks and pair selection.

On this Mac the local environment and weights already exist in the repository: `.venv-model/`, `local_vision/owl_detector.py` and `.cache/owlv2/`. The native development app finds them relative to the checkout; `PELAGIVEX_ROOT` can override that root for a relocated development app. The model worker sets Hugging Face offline mode. This is not a self-contained distributable installation of OWLv2. Its weights use Apache-2.0; see [the Google model card](https://huggingface.co/google/owlv2-base-patch16-ensemble) and [general-vision verification](../../../../GENERAL_VISION.md).

## Run

### 最新版感知工作台

The **3D** workspace captures a stationary object from many viewpoints through Camo or imports a photo folder, then runs Apple RealityKit Object Capture locally. It displays the actual textured USDZ with orbit/zoom/reset controls and export. Select **框选区域** in the live viewport to focus the object list and crop subsequently captured photographs. The region remains fixed during a scan; keep the entire object inside it. This is a separate reconstruction job, not a real-time 3D stream. See [capture instructions, provenance and reproducible validation](OBJECT_STUDIO.md).

Only the latest app bundle is retained in `dist`. Builds verify the replacement before publishing and remove the replaced bundle after success. Source models, research baselines and experimental evidence are retained.

The app opens into a single video surface with invisible controls. Click or tap the idle picture to start. Tap the upper left to start or stop, and tap the upper right or right-click the video for camera options. Double-click or double-tap the video to toggle full screen. The live view locks a visible object, retains the lock for up to 1.6 seconds after a missed detection, and gives it priority for SAM refinement. The 260 × 208 point 3D card looks for room on the opposite side and hides when no safe position fits. The wireframe rotates automatically. Drag to rotate it, or scroll or pinch to zoom. Zoom carries across target changes and temporary hiding.

The upper-right options menu also provides **高级工作台** for the existing research controls.

- **摄像头来源** selects Camo while capture is stopped. `⌘R` also starts or stops the camera.
- **目标** shows model names, confidence, observed/lost state and A/B shortcuts. Colors match the corresponding instance masks.
- **控制** contains recognition mode, Reference/Efficient preview, custom English queries, SAM, mirror, outline width and confidence threshold. Runtime details remain available in a disclosure panel.
- **相对深度** retains the distinct A/B selectors, **自适应** and **五秒基线**, with localized waiting, lost, too-close and fresh-result states.
- `⇧⌘F` returns from the running workbench to the single video view.

The instruments report actual detection/display FPS, SAM update rate, callback-to-GPU P95 and eligible fine-contour counts. Unavailable values are shown as dashes, and stopping clears them. The frame size in the video HUD is the analyzed pixel buffer; the footer camera status may report a larger capture format. No simulated telemetry, continuous scan animation or additional full-frame processing has been added.

The preceding console-only validation passed 59 Swift tests in 7 suites. Camo capture, target/control navigation, expanded view, text-mode controls, prompt validation, A/B selection and baseline/adaptive switching were checked in the running app. This is UI verification, not a new accuracy or sustained performance benchmark. [Validation and artifact hashes](../../../../.cache/ui-v09/validation.json). The original vector Dock icon is reproducible with `swift scripts/render_console_icon.swift ../../../../.cache/ui-v09/icon-rerun`; its previous version is backed up under the repository's `.cache/ui-v09/`.

**Performance → Efficient preview** is available to **Fast objects**. Stop the camera before switching. **Reference** is the default on launch. The optional model computes selected operations in FP16 and preserves class-index operations in FP32, using CPU/GPU. The modes can produce different scores and small-object masks. Efficient preview requests metric depth during A/B comparison or target analysis to reduce competition with recognition and fine contours. [Export and numerical audit](Model-YOLOE26s-PF-640-Mixed/README.md) · [Throughput, boundary-quality diagnostics and research plan](MAX_PERFORMANCE_RESEARCH.md).

These profile descriptions refer to the default build resources. `PELAGIVEX_MODEL_DIR` is an expert build override: if used, the Reference slot contains that supplied model, and its numerical precision/performance must be validated separately.

From this native module directory, open the current build:

```bash
open dist/PelagiVex.app
```

Wait for the model to load, then click **Start Camera** and grant access if prompted. Frames are not saved during ordinary recognition. Explicitly starting a 3D scan saves raw cropped photographs and a capture record under `~/Library/Application Support/PelagiVex/Scans/`; inputs and generated models remain available for reproduction. The app uses an ad-hoc local signature and is not notarized.

## Set up and build

Requires Apple Silicon, macOS 14+, Python 3.11 or 3.12, and Xcode Command Line Tools. The current checkout already contains the exported YOLOE bundle. For a fresh model reproduction, follow the pinned [YOLOE checkpoint preparation](../../../../model/yoloe26/README.md) and [FP32 export / parity procedure](Model-YOLOE26s-PF-640/README.md), including upstream license terms. From this module directory, build and open the existing bundle:

```bash
bash scripts/build.sh
open dist/PelagiVex.app
```

`scripts/setup_model.sh` is the historical YOLO11x export setup, retained for the study baseline; it does not prepare the current YOLOE default. SAM and OWLv2 remain development dependencies in the project environment. Their pinned setup is documented in [GENERAL_VISION.md](../../../../GENERAL_VISION.md#sam21-tiny-可复现安装).

The build normally runs the Swift Testing suite with `bash scripts/test.sh`. Use Swift 6 or later from Xcode or recent macOS Command Line Tools. To build without tests, explicitly run `bash scripts/build.sh --skip-tests`. If `coremlcompiler` is unavailable, the app compiles the bundled model when loading. Without the model, the app runs as camera preview only.

## Verification and limitations

```bash
bash scripts/test.sh
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

The YOLOE exporter verifies output layout and PyTorch/Core ML parity on synthetic and real letterboxed inputs. The default bundle uses FP32 computation: a blanket FP16 conversion was rejected after changing odd class IDs above 2,048. The optional efficient profile protects these operations and has a separate numerical audit. These checks are not accuracy benchmarks. The vocabulary has 4,585 names, not an exhaustive reliable label for every object. Fine, transparent and occluded parts may still be missed. The UI timing measurements are not guarantees or full physical display latency.

The v0.7 build passes **59 Swift tests across 7 suites**, including confirmation, label changes and contour age/identity/geometry gates. Local SAM FP32 optimization retained identical instance-ID pixels against the original FP32 selection on two checked saved inputs; warmed worker medians were about **105 ms for two objects / 116 ms for five**. Experimental FP16 autocast changed pixels and remains disabled. These are isolated calls, excluding the full camera path and cold start, and do not establish sustained throughput or contour accuracy. [SAM profiling records](../../../../.cache/general-vision/sam-profile/results.json). Historical v0.6 serial-SAM camera readings are retained separately in [GENERAL_VISION.md](../../../../GENERAL_VISION.md).

[REALTIME_CONTOURS.md](REALTIME_CONTOURS.md) records the same-model serial/background scheduler comparison, current Camo snapshots, raw results and reproduction commands. The offline scheduler feeds saved public Bonn frames at an artificial 30 Hz and excludes rendering and depth. It measures scheduling throughput and processing latency, not original-video timing, sustained phone-camera FPS or recognition accuracy.

## Approximate depth

The object list shows a color matching each mask and an uncalibrated estimate of forward depth, not a measured straight-line distance. The existing Depth Anything V2 Metric Indoor Base model runs locally in a separate Python worker using the project root `.venv-model` and `model/local-depth/`. Its weights are CC BY-NC 4.0. The estimate takes the median over valid depth pixels inside the instance mask, with a small interior erosion when possible, to reduce background contamination. Inaccurate masks, occlusion, motion and scene conditions can still cause large errors; no improvement in real-world accuracy is claimed without measured reference distances. Depth updates are slower than video, may lag, and expire after five seconds. This Mac has a local copy of the depth environment and weights under `~/Library/Application Support/PelagiVex`. If it is missing, the development build falls back to the project root.

## Object confidence and short dropouts

The list shows up to 100 accepted detections and winning class confidence. The old YOLO11 head can expose alternatives; the YOLOE end-to-end export provides the winning class and score. Scores are not calibrated correctness probabilities. Unsupported objects, scene words and similar names can be confused.

The **New-object confidence** slider defaults to 25%; lower it toward 15% to include more candidates or raise it to reduce false detections. Existing tracks may continue from observations down to 10%, so an established target can remain visible below the new-object threshold. This does not turn a weak observation into a confident classification.

The YOLOE path now requires two consecutive qualifying observations before publishing a new target or a persistent label change, adding a short confirmation delay. Conservative class-independent ID recovery is limited to recent, confirmed tracks with strong, mutually exclusive geometry. A pending different label is withheld rather than published with an old label or score.

Missing-track metadata is normally retained for 0.8 seconds; the slower text-guided path permits up to 4 seconds. Missing rows are gray with their last score and age. Long occlusion, abrupt motion and similar objects can still confuse identities. Old masks and depth are not projected into a missing target's new frame. [Tracking verification and replay](TRACKING_UPDATE.md)

On the cached real Bonn Crowd3 input, the confirmation/recovery change reduced accepted scene observations from 545 to 469. The existing manually identified target alias retained 70 of 71 observations, versus 71 previously, and had one ID change with either tracker. This shows a coverage cost and no identity-fragmentation improvement for that real target; constructed label-blip tests do not establish general real-world accuracy. [Inputs, results and reproduction](../../../../.cache/yoloe26/tracker-confirmation/README.md)

## Compare two objects

Open the development build at `dist/PelagiVex.app`. Choose **Camo Camera** for a connected phone or use **Automatic (built-in first)**. Start the camera, then select two different detected track IDs under **Compare Two Objects**. The A and B labels in the object list identify the selection. For a quick check, hold two recognizable objects apart laterally, put one closer, then swap their forward positions without hiding either object.

**Adaptive** displays the closer object when it has usable depth evidence. A change in apparent size or overlap can hide an old direction and defer its replacement briefly so the next inference can see the other side of a change. Routine refresh leaves spare credit when possible. The request budget refills at one depth call every two seconds, and evidence expires after three seconds. If the two depth estimates are within 5 cm or 5% of the nearer depth, whichever is greater, the panel displays **Too close to call**. Reselect a lost object if it returns with a new track ID.

**Five-second baseline** uses the existing two-second depth request cadence and displays measurements for up to five seconds, provided both selected tracks are visible. The [RGB-D replay notes](PAIR_STUDY.md) describe the real-footage comparison and include commands to reproduce it locally.

Historical `--pair-trace` keeps the original YOLO11 model, 35% / 25-object filter and one-frame tracker in the separate LegacyStudyModel resource. The live model upgrade does not change the saved study. `--tracking-replay` compares trackers on identical cached observations.

## Fine-tuning and architecture

The live prompt-free checkpoint is a deployment model. Its trainable twin, editable YAML, checksums and verified loading procedure are saved under [model/yoloe26](../../../../model/yoloe26/README.md). [MODEL_ROADMAP.md](../../../../MODEL_ROADMAP.md) documents the correct training entry point and comparison plan. No training has been run without a real labelled dataset. Any newly trained model must pass export, numerical-parity and real-frame checks before replacing the live bundle.

## Cameras

The Camera menu lists devices recognized by macOS. Automatic mode prefers the built-in camera. Stop the camera before changing the selection. For Camo, open Camo on the phone and make sure Camo Studio is receiving the phone image before choosing **Camo Camera**. Camera authorization is controlled by macOS and a locally ad-hoc-signed rebuild can request access again.
