# Real-time fine contours — v0.7, 2026-11-07

The automatic detector no longer waits for SAM. Each new YOLOE frame is rendered immediately; a separate serial worker accepts at most one SAM request and keeps no backlog. Fine contours from a completed request are mapped to current confirmed tracks on the GPU. This improves visual responsiveness; it does not make the SAM network itself run at 30 Hz.

## Evidence lifetime and failure behavior

- Each reused contour requires a unique positive track ID, the same class, a source/frame and wall-clock age of at most 0.65 seconds, box IoU of at least 0.45, and width/height ratios in 0.7–1.4.
- Old masks are mapped by their original instance index to the current detection-array index. Reordering detections cannot swap colors or objects.
- Unmatched, stale, rapidly moving or rescaled objects use the current YOLOE mask. If the shared SAM instance map has no pixels for an object because a higher-priority mask covered it, that object also retains its current native contour. A missing detection gets no invented current mask.
- Mapping is an affine transform between object boxes. It is not optical flow and does not establish correct boundaries under deformation, internal motion or an unnoticed identity swap. The gates are conservative engineering choices, not calibrated guarantees.
- The UI reports detector FPS, unique displayed-frame FPS, SAM refresh FPS, worker time, SAM source age, and the number of currently eligible refined targets separately.

## Reproducible offline scheduler experiment

Both modes use the same FP32 YOLOE26 checkpoint, new tracker configuration, local SAM model and optimized worker. The first 120 saved Bonn crowd RGB frames are cycled at 30 input frames/second for 25 seconds, excluding the first 5 seconds from the reported rate. The synchronous mode waits for SAM; the asynchronous mode keeps detecting while SAM is busy. A slow mode skips offered frame times, as a latest-frame camera pipeline does. This is an artificial scheduler stress test, not the original recording's time scale, a paired accuracy evaluation, or camera/display throughput. Rendering and depth are excluded.

| Scheduling | Warm completed frames / 20 s | Detector throughput | Processing latency P50 | P95 |
| --- | ---: | ---: | ---: | ---: |
| Serial SAM | 132 | 6.60 FPS | 149.12 ms | 174.17 ms |
| Background SAM | 544 | 27.20 FPS | 33.94 ms | 56.72 ms |

The asynchronous output contained 81 distinct completed SAM results during the warm interval; 100% of processed frames had a cached result no older than 0.65 s. This age statistic does not prove per-object eligibility or contour accuracy. Mean visible objects differed (7.23 serial, 14.46 async), because skipping input frames changes tracking/confirmation; these are throughput observations, not a recall comparison.

Run from this native app directory after `bash scripts/build.sh`:

```sh
study="$(git rev-parse --show-toplevel)/.cache/pair-study/bonn-crowd3/rgb"
results="$(git rev-parse --show-toplevel)/.cache/general-vision/async-contours"
dist/PelagiVex.app/Contents/MacOS/PelagiVexNative --contour-benchmark serial "$study" "$results/serial.json" 25
dist/PelagiVex.app/Contents/MacOS/PelagiVexNative --contour-benchmark async "$study" "$results/async.json" 25
```

After the final absent-instance fallback change, an additional 25-second asynchronous run returned 26.55 FPS and 58.94 ms P95. See [final verification](../../../../.cache/general-vision/async-contours/async-final.json). The repeated asynchronous rates were 26.4–27.2 FPS, rather than a sustained 30 FPS claim.

Do not run the two modes concurrently. Results include exact source paths and per-frame timings. The input images already belong to the public RGB-D dataset cache; this test saves no phone-camera frames.

## Native Camo check

The v0.7 release compiled its Metal kernels, loaded the model and started Camo at 1920×1080 with fine contours enabled. After the user moved the phone/scene, an observed snapshot showed 21.6 detector FPS, 19.4 display FPS, 60 ms analyzed-frame age, 2.2 SAM updates/second and 6/25 eligible fine contours. A later snapshot expired all old fine contours and used current segmentation. After the GPU-composition update, another snapshot showed 23.5 detector FPS, 23.1 display FPS, 100 ms frame age, 2.4 SAM updates/second, and 18/22 eligible targets. Other snapshots during shared CPU/GPU load were lower (down to about 15 display FPS); these are transient observations, not a sustained 30 FPS claim. The final build was reopened and Camo restarted: 22.9 detector FPS, 21.8 display FPS, 150 ms analyzed-frame age, 2.2 SAM updates/second, and 20/21 eligible fine contours in its renderer snapshot. UI counters update asynchronously, so the object list can briefly report a different count. No synchronized movement recording or independent boundary ground truth was captured.

## False detections and tracking

The end-to-end detector now opts into two-observation confirmation. An unambiguous, very recent geometric match can retain an ID across a winning-label change. A changed label must also be confirmed; no previous label's confidence is attached to a new observation. These rules suppress short-lived errors at the cost of initial/changed-label coverage.

The retained synthetic 30 Hz test reduced four isolated false detections to zero, two wrong-label observations to zero, and five ID changes to zero; accepted target observations fell from 115 to 111 and confirmation added about 33 ms. In the real cached Bonn trace, the manually associated target had 71 versus 70 accepted observations and one ID change in both modes; all-scene accepted observations fell from 545 to 469. There is therefore no demonstrated improvement in real false-positive rate or recall. See the exact input hashes and replay instructions in [tracker audit](../../../../.cache/yoloe26/tracker-confirmation/README.md).

## Validation and remaining work

59 Swift tests in seven suites and 17 Python worker/refinement tests pass. Swift checks cover the tracker, decoder, mask ID mapping, propagation geometry, expiry, and original pair policy. The 12 historical pair-replay reports remain byte-identical. Current camera masks and the Metal rendering path were visually checked; affine propagation has not yet been evaluated against per-frame contour truth.

The pinned SAM profile preserved FP32 best-IoU mask selection, with zero changed pixels on two reference images and a 25-box synthetic load. The final worker composes instance IDs on the GPU and transfers one byte raster. At 25 boxes this reduced its median from 262.1 to 260.2 ms versus the prior selected-mask path, a small gain; the large throughput improvement comes from asynchronous scheduling. Its image encoder is the main cost. A CPU_AND_NE deployment experiment for YOLOE was rejected: about 345 ms per warmed model call, despite matching labels and masks. The app retains Core ML ALL. The CPU/Neural Engine result does not establish which processor ran each operator.

Source and result records:

- [SAM profiling script](scripts/profile_segmentation_refiner.py) and [saved profile](../../../../.cache/general-vision/sam-profile/results.json).
- [Serial scheduler result](../../../../.cache/general-vision/async-contours/serial.json) and [asynchronous result](../../../../.cache/general-vision/async-contours/async.json).
- [25-box composition/parity profile](../../../../.cache/general-vision/sam-profile/composition-stress-25-results.json).
- [CPU/Neural Engine audit](../../../../.cache/yoloe26/cpu-ne-audit.json).
- [Native scheduler benchmark source](Sources/PelagiVexNative/ContourBenchmark.swift).

[Native observation log and final source hashes](../../../../.cache/general-vision/async-contours/native-validation.json).

## Camo fixed-window verification

With SAM enabled, `--camo-live-benchmark` runs the normal camera, recognition, tracking and Metal view. It records unique-frame rate summaries, SAM completions, fine contour coverage and anonymized track transitions. It writes numeric metrics and does not save camera images. Run it while the phone is supplying Camo frames and with other PelagiVex windows closed.

```bash
app="$PWD/dist/PelagiVex.app"
open -n -W -a "$app" --args --camo-live-benchmark /tmp/pelagivex-camo-new.json 20 reference
open -n -W -a "$app" --args --camo-live-benchmark /tmp/pelagivex-camo-live-new.json 24 efficient live
```

The trailing `live` runs the live camera layout and requires successful automatic lock, a visible 3D card and new rendered frames while the card is visible. The same build accepts `--env PELAGIVEX_RENDER_BASELINE=1` before `--args` for the prior Metal composition and repeated draw behavior. To isolate unselected-object depth in the benchmark, pass `--env PELAGIVEX_BENCH_AMBIENT_DEPTH=on` or `--env PELAGIVEX_BENCH_AMBIENT_DEPTH=off`. The `efficient` profile uses the optional mixed precision detector and requests depth during A/B comparison or target analysis. Reported fine coverage counts display-eligible results and does not measure contour accuracy. Live tracking samples do not have identity ground truth. Results for the live view are in the repository-root `.cache/live-camera-study/`. The earlier renderer comparison and pixel parity fixture are in `.cache/sam-camo-study/`.

