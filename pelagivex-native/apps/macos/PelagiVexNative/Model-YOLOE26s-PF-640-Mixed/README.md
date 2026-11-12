# YOLOE26s PF mixed precision experiment

This is a separate 23.50 MiB Core ML experiment derived from the same official YOLOE26s prompt-free checkpoint as the FP32 reference bundle. It uses the same 4,585-name vocabulary, 640 px RGB input and schema-2 end-to-end segmentation layout. It is intended as a selectable efficiency preview. The FP32 reference bundle has not been replaced.

The previous unguarded FP16 export rounded odd class IDs above 2048. This version uses Core ML's selective precision transform: convolution, vocabulary projection and mask features can be FP16, while the integer-to-FP32 class index and the subsequent class gather and output concatenation remain FP32. A forced-logit probe returned the exact IDs 2049, 3123, 3927, 3963, 4353 and 4583. The output is still a winning class and raw model score; the score is not a calibrated probability.

The first CPU_AND_NE load timed out while the shared ANE compiler was busy. With the compiler idle, a retry loaded in 1.45 s and completed eight warm predictions of the same saved frame at **21.68 ms median and 24.26 ms p95**. Core ML's static compute plan preferred the Neural Engine for 319 operations, representing 84.46% of estimated cost. Class 3927 kept its exact ID, and its raw score fell from 0.174 to 0.027 relative to FP32. [Apple's typed execution guide](https://apple.github.io/coremltools/docs-guides/source/typed-execution.html)

The efficiency preview uses CPU_AND_GPU. On this Apple M5 Pro, it took 0.272 s to load, 5.983 s for the first saved-frame prediction, then **12.19 ms median and 14.10 ms p95** across ten warm predictions of that frame. Both backend trials measured standalone model prediction with the camera and refinement worker stopped. Core ML's static CPU_AND_GPU plan preferred the GPU for 336 operations, representing all of the estimated cost. The first-call cost is material and should be warmed before measuring steady state.

The CPU_AND_GPU parity comparison uses nine real Bonn RGB-D images from three cached public sequences and two synthetic inputs. Both models receive the exact same saved square RGB pixels. The independent reference is the verified FP32 Core ML bundle in CPU_ONLY mode. All 300 returned rows were counted at each threshold, and pairs require matching class and box IoU ≥0.5 after class-blind assignment.

| Reference confidence threshold | FP32 visible rows | Mixed visible rows | Paired visible rows | Mean assigned 160px mask IoU |
| --- | ---: | ---: | ---: | ---: |
| 0.10 | 184 | 183 | 182 | 0.99370 |
| 0.25 | 86 | 86 | 86 | 0.99525 |
| 0.35 | 65 | 65 | 65 | 0.99378 |
| 0.50 | 49 | 50 | 49 | 0.99420 |

At 0.25 the 86 class labels agree, the mask IoU p05 is 0.97327, and the minimum is 0.88732. Normalized mean box-error p95 is 0.0002015. At 0.10 there is a weak `doorplate` → `light switch` label change and another reference row drops below threshold. These are conversion-agreement metrics, not recall, precision or accuracy against ground truth.

Confidence values can still move materially. For class 4353 (`veterinarians office`) in the original real frame, the full FP32 tensor contains scores 0.441308, 0.233920 and 0.000336, whereas Mixed CPU_AND_GPU contains 0.643066, 0.011734 and 0.000360. Their boxes and binary masks align closely, and the top score exceeds every reference score for that class, so swapping matched rows cannot explain it. This is separate from numeric class-index corruption. The 0.25-slice absolute score error has p95 0.00479 and maximum 0.20176. Retain the FP32 reference when these raw scores matter.

`export-report.json` preserves checkpoint and model-file hashes, the selector audit and package bytes. `mask-parity-audit-cpu_and_gpu.json`, `candidate-tensors-cpu_and_gpu.npz` and `score-outlier-audit.json` preserve the image-wise outputs and score evidence. `performance-cpu_and_gpu.json` and `performance-cpu_and_ne.json` contain warm timings and static compute plans. `performance-cpu_and_ne-retry.json` records the retry conditions and exact class-index checks. `performance-cpu_and_ne-blocked.json` records the first load timeout.

From the repository root, reproduce with the existing isolated environment:

```sh
PYTHONPATH="$PWD/.cache/yoloe26/coreml-deps:$PWD/.cache/yoloe26/ultralytics-deps" \
  YOLO_AUTOINSTALL=false .venv-model/bin/python \
  pelagivex-native/apps/macos/PelagiVexNative/scripts/export_yoloe_mixed.py \
  --checkpoint .cache/yoloe26/yoloe-26s-seg-pf.pt \
  --reference-bundle pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640 \
  --output pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640-Mixed-reproduction \
  --strategy index-safe \
  --extra-frame .cache/pair-study/bonn-chairs-near/rgb/0281.png \
  --extra-frame .cache/pair-study/bonn-chairs-near/rgb/0487.png \
  --extra-frame .cache/pair-study/bonn-chairs-near/rgb/0120.png \
  --extra-frame .cache/pair-study/bonn-chairs-far/rgb/0915.png \
  --extra-frame .cache/pair-study/bonn-chairs-far/rgb/0726.png \
  --extra-frame .cache/pair-study/bonn-crowd3/rgb/0054.png \
  --extra-frame .cache/pair-study/bonn-crowd3/rgb/0242.png \
  --extra-frame .cache/pair-study/bonn-crowd3/rgb/0337.png

pelagi_mixed_repro="pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640-Mixed-reproduction"

PYTHONPATH="$PWD/.cache/yoloe26/coreml-deps:$PWD/.cache/yoloe26/ultralytics-deps" \
  .venv-model/bin/python .cache/yoloe26/mixed-audit.py --phase parity --bundle "$pelagi_mixed_repro"

PYTHONPATH="$PWD/.cache/yoloe26/coreml-deps:$PWD/.cache/yoloe26/ultralytics-deps" \
  .venv-model/bin/python .cache/yoloe26/mixed-audit.py --phase parity --parity-device CPU_AND_GPU --bundle "$pelagi_mixed_repro"

PYTHONPATH="$PWD/.cache/yoloe26/coreml-deps:$PWD/.cache/yoloe26/ultralytics-deps" \
  .venv-model/bin/python .cache/yoloe26/mixed-audit.py --phase performance --units CPU_AND_GPU --repetitions 10 --bundle "$pelagi_mixed_repro"
```

The upstream checkpoint and model code are AGPL-3.0; see [Ultralytics licensing](https://www.ultralytics.com/license).
