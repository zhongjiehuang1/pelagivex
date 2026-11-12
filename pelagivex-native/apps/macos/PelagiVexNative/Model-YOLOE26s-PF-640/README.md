# YOLOE26s prompt-free native bundle

This is an official 4,585-name prompt-free checkpoint exported locally to Core ML, not a new trained model. The vocabulary includes scene names and descriptive concepts as well as physical objects. Its winning confidence is not a calibrated probability, and it cannot recognize everything in a scene.

`model.json` is an inspected schema-2 contract: RGB `image` at 640 square pixels; `var_1558` is `[1,300,38]` with pixel-space xyxy, winning score, integer-valued class index, and 32 mask coefficients; `var_1637` is `[1,32,160,160]` mask prototypes. The exporter explicitly selects `nms=False`, which enables the one-to-one end-to-end head. The default loaded PyTorch checkpoint instead selects a different, one-to-many prompt-free branch.

The published model uses FP32 compute. Official FP16 conversion changed class IDs on the real frame, including 4353→4352, 3963→3964 and 3927→3928. FP16 cannot represent every integer above 2048. The rejected attempt is retained in `.cache/yoloe26/export-fp16.log`; no FP16 model from that attempt is published here.

`export-report.json` records the official checkpoint URL, SHA-256, AGPL-3.0 policy link, dependency versions, export arguments, package hashes, and conversion checks. Both backends received identical saved RGB square inputs: two synthetic inputs and a real, letterboxed Bonn RGB-D frame from the existing project cache. This checks conversion, not recognition accuracy or a live camera. All 11 real-frame reference detections above 0.10 confidence retained their labels in FP32. Core ML CPU_ONLY prototype mean absolute error was 1.29e-6.

`compute-unit-audit.json` compares Core ML ALL against the verified CPU_ONLY output. On this Apple M5 Pro, five warmed `MLModel.predict` calls had a median 38.16 ms on the real input, 35.66 ms on gray and 44.49 ms on random pixels. Those timings exclude camera capture, letterboxing, result decoding, tracking and rendering and therefore do not measure application FPS. ALL retained all 11 confident real-frame labels.

From the repository root, reproduce in an isolated environment containing `scripts/requirements-yoloe-export.txt` (paths below assume the existing local dependency targets). The exporter refuses to replace an existing destination, including the old YOLO11 bundle:

```sh
PYTHONPATH="$PWD/.cache/yoloe26/coreml-deps:$PWD/.cache/yoloe26/ultralytics-deps" \
  YOLO_AUTOINSTALL=false .venv-model/bin/python \
  pelagivex-native/apps/macos/PelagiVexNative/scripts/export_yoloe.py \
  --checkpoint .cache/yoloe26/yoloe-26s-seg-pf.pt \
  --real-frame .cache/pair-study/bonn-chairs-near/rgb/0083.png \
  --output pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640-reproduction \
  --size 640 --quantize 32

PYTHONPATH="$PWD/.cache/yoloe26/coreml-deps:$PWD/.cache/yoloe26/ultralytics-deps" \
  .venv-model/bin/python \
  pelagivex-native/apps/macos/PelagiVexNative/scripts/audit_yoloe_coreml.py \
  pelagivex-native/apps/macos/PelagiVexNative/Model-YOLOE26s-PF-640-reproduction
```

For training and architecture work, use the text/visual twin `yoloe-26s-seg.pt` and `YOLOEPESegTrainer`. The PF checkpoint rejects `set_classes()` and is not directly trainable. Official documentation: <https://docs.ultralytics.com/models/yoloe>, <https://docs.ultralytics.com/integrations/coreml>. Model and upstream code are AGPL-3.0; the official commercial licensing policy is <https://www.ultralytics.com/license>.
