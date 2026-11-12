# Model interface, version 1

Model folder: `model.json` plus `UniversalSeg.mlpackage` (or a compiled `UniversalSeg.mlmodelc`).
The exporter discovers actual input/output names from the exported spec. Names are not hard-coded guesses.

- `schema`: 1; `format`: `yolo-v8-11-seg`.
- RGB image input, fixed square `inputSize` (384/512/640 exporter choices); Core ML applies 1/255 scaling.
- App letterboxing: preserve aspect ratio, centered padding RGB 114; image coordinates start at top-left.
- Predictions `[1, 4+classCount+maskChannels, predictionCount]`, channel-major after stride-aware copying.
- First four channels: center-x, center-y, width, height in **input image pixels**, not normalized.
- Next classCount channels: class probabilities, **no additional objectness** and no extra sigmoid.
- Last maskChannels: mask coefficients.
- Prototypes `[1,maskChannels,prototypeHeight,prototypeWidth]`.
- Mask inside each selected box: `dot(coefficients, prototypes) > 0`, equivalent to sigmoid > 0.5.
- NMS: class-aware, confidence >=0.35, IoU >0.5 suppressed, maximum 25 output instances.
- Higher-confidence instance wins a conflicting displayed pixel; this is a display policy, not ground-truth depth.
- The source frame and its mask are published as one immutable packet. No stale-mask/live-frame overlay.

Scores are model estimates, not calibrated correctness probabilities.
Prototype-resolution masks are not perfect contours; export smoke tests do not establish task accuracy.
The water-gate ONNX model, YOLO detection-only exports, NMS-wrapped exports, and end-to-end YOLO26 outputs
are deliberately rejected rather than being silently misinterpreted.

Export provenance records hashes of downloaded files, not a publisher-signed authenticity guarantee.
Only load trusted model packages; neural-network parsers are not a sandbox for arbitrary untrusted inputs.
