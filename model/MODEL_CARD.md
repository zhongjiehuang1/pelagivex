# Pelagivex Gate Detector — prototype model card

## Purpose and limits

Single-class bounding-box detection of an underwater competition-style gate in
still RGB images. Research/demo only; not validated for robotic navigation,
collision avoidance, safety-critical decisions, or any particular team's
camera. Scores are model confidence, not guaranteed probabilities of correctness.

## Architecture and source

- RF-DETR Nano 1.4.0, COCO-pretrained weights fine-tuned for a single `Gate`
  class. RF-DETR code and Nano model are described as Apache-2.0 by their
  [publisher](https://github.com/roboflow/rf-detr). Official pretrained weights:
  <https://storage.googleapis.com/rfdetr/nano_coco/checkpoint_best_regular.pth>.
- Fine-tuning images and labels: mo_bilal14,
  [GateDetection Dataset](https://www.kaggle.com/datasets/mobilal14/sauvc-dataset).
  Kaggle's API lists its license as MIT. The uploader's rights to all original
  capture sources have not been independently established. Do not redistribute
  original images without confirming the provenance and applicable terms.
- Cross-source synthetic challenge: [jack-www/sauvc-v1](https://huggingface.co/datasets/jack-www/sauvc-v1),
  marked MIT by its publisher. These are rendered simulation scenes, not
  underwater photographs. The challenge layouts were chosen before inference.

## Training and selection

- Three epochs total on Apple M5 Pro, 24 GB unified memory, PyTorch 2.8.0,
  torchvision 0.23.0, RF-DETR 1.4.0, Python 3.12, Apple MPS with CPU fallback.
- Prepared dataset: 1,000 training images (618 with a Gate annotation) and
  120 validation images (102 Gate boxes). Non-Gate labels are removed while
  Gate-free images remain negative examples.
- Checkpoint selection: highest validation COCO AP at IoU 0.50–0.95 across
  the three epochs, yielding epoch 3 (0.8514; validation AP50 0.9752).
  The confidence threshold **0.20** was then selected only from a fixed set of
  candidate thresholds on validation F1. Both choices preceded final holdout
  inference.
- A separate 150-image original-test subset was used for preliminary checks;
  it is not counted as the final holdout. An additional 231 original test
  images, after excluding exact duplicates across prepared sets, were reserved
  and evaluated once after checkpoint and threshold selection.

## Frozen-threshold evaluation

At score >= 0.20, one-to-one class-matched bounding-box IoU >= 0.50, maximum 25
detections per image:

| Evaluation | Images | True positives | False positives | False negatives | Precision | Recall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Original-source held-out subset | 231 | 149 | 6 | 4 | 96.1% | 97.4% |
| Sensitivity subset after near-match screening | 152 | 84 | 4 | 2 | 95.5% | 97.7% |
| Cross-source simulated challenge | 10 | 9 | 3 | 3 | 75.0% | 75.0% |

**Important limitation:** the source dataset does not identify recording/video
groups. Perceptual dHash screening found 79 of the 231 final test images within
3 of 64 bits of a training frame; the 152-image row excludes those images.
dHash is a heuristic and neither row proves independent-scene generalization.
The 10 simulated images are a small exploratory challenge, not evidence of
real-world robustness. None of these results establishes performance on
Project Trident's imagery or competition hardware.

## Artifact and reproduction

- Selected ONNX: `model/gate-v2.onnx` (not tracked in Git), SHA-256
  `48b7e5f293a0fd1be254cf6565dad1c0e3453bfb45384b0ff8e619a7c5146381`.
- Selected fine-tuned checkpoint (local only):
  `runs/gate-3epoch/checkpoint_best_total.pth`, SHA-256
  `2c82653e37a4d29dc7e7c5ec3a688eb97a428661bca01c54fbed5c65034623c4`.
- Source dataset ZIP SHA-256:
  `21c8945ee247c390f99d4c0e4515151f7e987e764b1c15e1655dece16b5da983`.
- Downloaded RF-DETR Nano starting checkpoint SHA-256:
  `d8d6b9ee57d4d0ed2b1f305163624712a0532cb7bce0c747317984fc5457440d`.
- Reproducible preparation, training, selection, export and evaluation scripts
  are in `scripts/`; pinned local dependencies are in
  `model/requirements-training.txt`. Source images, full per-image results,
  and full checkpoints are not uploaded with the Git repository.
- Local reports: `runs/selected-model.json`,
  `runs/frozen-validation-threshold.json`, `runs/final-evaluation.json`,
  `runs/finalholdout-similarity.json`, and `runs/synthetic-challenge.json`.
  Aggregate figures are also recorded in `model/evaluation.json`.
