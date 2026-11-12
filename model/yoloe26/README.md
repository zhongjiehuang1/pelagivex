# YOLOE-26s deployment and research starting point

The automatic broad-vocabulary checkpoint is `yoloe-26s-seg-pf.pt`. It predicts from the official 4,585-name vocabulary and includes instance masks. It is not an exhaustive recognizer, and the vocabulary includes scene terms and attributes as well as physical objects. The two-frame local smoke test is not an accuracy benchmark or evidence of global state of the art.

The separate `yoloe-26s-seg.pt` checkpoint is the trainable text/visual-prompt twin. The official prompt-free checkpoint is derived for inference; it does not support directly setting text classes or the standard fine-tuning path. Both downloads are already cached in `.cache/yoloe26/`.

## Isolated package and official checkpoints

Run from the repository root. The existing `.venv-model` remains unchanged. The Ultralytics source package is isolated in a project cache and pinned to the same version used by the existing exporter.

```bash
.venv-model/bin/python -m pip install --target .cache/yoloe26/ultralytics-deps \
  --no-deps ultralytics==8.4.193
curl -fL --retry 2 \
  https://github.com/ultralytics/assets/releases/download/v8.4.0/yoloe-26s-seg-pf.pt \
  -o .cache/yoloe26/yoloe-26s-seg-pf.pt
curl -fL --retry 2 \
  https://github.com/ultralytics/assets/releases/download/v8.4.0/yoloe-26s-seg.pt \
  -o .cache/yoloe26/yoloe-26s-seg.pt
shasum -a 256 .cache/yoloe26/yoloe-26s-seg*.pt
```

SHA-256:

- Prompt-free: `01605da3f2e0e5325df45d5f5eef8e40b5b5c7d085399be3c33ac638258b150a`
- Trainable twin: `48f24206bc8680d60cbbfa296b0140da849669b9515058b72f5a945142df0654`

The current local inference environment has PyTorch 2.8.0, torchvision 0.23.0, NumPy 2.5.4 and MPS support. The isolated install command supplies only Ultralytics and relies on that existing environment; it is not a complete cross-machine dependency lock. Core ML conversion has a separate isolated dependency directory and validation report.

## Editable architecture

`yoloe-26s-seg.yaml` is an editable copy of the architecture in Ultralytics 8.4.193, retaining its license header. The filename carries the `s` scale deliberately: this Ultralytics loader infers scale from the filename and can silently fall back to `n` for a generic `architecture.yaml`, even when the YAML contains `scale: s`.

This construction was executed successfully, with **958/958 checkpoint items transferred**, before any architecture changes:

```bash
PYTHONPATH="$PWD/.cache/yoloe26/ultralytics-deps" .venv-model/bin/python - <<'PY'
from ultralytics import YOLOE
model = YOLOE("model/yoloe26/yoloe-26s-seg.yaml")
model.load(".cache/yoloe26/yoloe-26s-seg.pt")
print(model.model.yaml["scale"])
PY
```

Future modifications can change the backbone, neck or segmentation head in this YAML. Changing dimensions may intentionally prevent some pretrained tensors from loading; record the transferred items and compare against this unchanged architecture. No fine-tuning has been performed, and no architecture improvement is claimed.

When instance-mask annotations and a separate validation split are ready, the official segmentation fine-tuning path is:

```python
from ultralytics import YOLOE
from ultralytics.models.yolo.yoloe import YOLOEPESegTrainer

model = YOLOE(".cache/yoloe26/yoloe-26s-seg.pt")
# Run only after replacing this with a real, validated dataset:
# model.train(data="/absolute/path/to/dataset.yaml",
#             trainer=YOLOEPESegTrainer, device="mps", imgsz=640,
#             batch=1, workers=0, epochs=20, seed=7)
```

The current native detector contract is separate from the training checkpoint's raw head layout. A newly trained model must be exported and pass output-layout, numerical-parity and real-frame checks before replacing the application model.

## Local smoke measurements

The historical **v0.6 serial-SAM** app was checked with **Camo Camera at 1920×1080**. With extra SAM refinement disabled, UI snapshots showed 30 inference FPS, about 28 display FPS and 20–21 ms Core ML calls. With SAM enabled, snapshots ranged from 3.5 to 6 inference FPS, with visibly finer boundaries. These are transient historical observations, not current v0.7 throughput or accuracy benchmarks. Settings, counter scope and that build's checks are saved in [`native-validation.json`](native-validation.json). Camera frames were neither saved nor uploaded.

The current **v0.7** app decouples SAM updates from detection/display and propagates eligible recent contours by track ID and conservative geometry. It reports SAM refresh separately from detector/display FPS. Current offline scheduler results, Camo observations and limitations are in [REALTIME_CONTOURS.md](../../pelagivex-native/apps/macos/PelagiVexNative/REALTIME_CONTOURS.md).

`.cache/yoloe26/mps-benchmark.json` records two real public RGB-D dataset images, each repeated four times with square 640 input. After first-call initialization, full Python prediction, mask postprocessing and MPS synchronization took approximately 46–77 ms. These momentary measurements are not native Core ML FPS or sustained camera throughput.

Reproduce the timing with the saved dataset inputs:

```bash
PYTHONPATH="$PWD/.cache/yoloe26/ultralytics-deps" \
  .venv-model/bin/python model/yoloe26/benchmark.py \
  --output .cache/yoloe26/mps-benchmark-rerun.json
```

The two chairs were labeled `chair` at about 0.897/0.896 confidence. The crowded frame included `person`, `laptop`, `chair` and more specific terms. It also produced questionable scene/attribute labels such as `clinic`, `modern` and `hospital room`. Wider vocabulary increases opportunities and false labels. Scores are not calibrated correctness probabilities.

## Primary references and license

- [Official YOLOE modes, exports and fine-tuning](https://docs.ultralytics.com/models/yoloe/)
- [Official YOLO26 model family](https://docs.ultralytics.com/models/yolo26/)
- [Official checkpoint release](https://github.com/ultralytics/assets/releases/tag/v8.4.0)
- [Ultralytics licensing](https://www.ultralytics.com/license)

The source architecture is supplied under the upstream AGPL-3.0 notice. Check the applicable upstream model/code terms before redistribution or proprietary deployment; an optional commercial license is separate from this local research preparation.
