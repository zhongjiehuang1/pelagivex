# Gate detector provenance

Pelagivex uses a single-class object detector for underwater gate images.
This is an experimental image detector, not an autonomous-navigation or safety
system. It does not recognize every kind of underwater object or gate.

## Model and training data

- Architecture: RF-DETR Nano, pretrained on COCO and fine-tuned on a Gate-only
  subset with PyTorch / RF-DETR. RF-DETR is licensed Apache-2.0:
  <https://github.com/roboflow/rf-detr>. Pretrained checkpoint used by the
  official RF-DETR 1.4.0 package:
  <https://storage.googleapis.com/rfdetr/nano_coco/checkpoint_best_regular.pth>.
- Dataset: mo_bilal14, *GateDetection Dataset*,
  <https://www.kaggle.com/datasets/mobilal14/sauvc-dataset>. The Kaggle API
  lists its license as MIT. The uploader's source-image rights and original
  recording provenance were not independently established; this is not a
  guarantee that every original image is cleared for redistribution.
- The source has Gate and Flare categories. We keep only Gate annotations;
  images without Gate are retained as negative examples. The subset contains
  1,000 training images and 120 validation images. Its exploratory test split
  contained 150 images; 231 additional original test images were reserved for a
  final holdout. Exact duplicates across sets were screened where prepared.
- Images come from the dataset uploader's existing split. The source does not
  document video/session grouping, and near-duplicate frames were detected
  across splits. Metrics therefore do not prove performance on independent
  scenes or Project Trident footage.
- Training and prepared data are excluded from Git. Do not republish images
  without checking their rights. A separate, explicitly identified simulated
  scene can be used for illustration.

## Model contract

The exported ONNX model consumes a normalized RGB float tensor of shape
`[1,3,384,384]`. Outputs are `dets` (normalized centre-x, centre-y, width,
height) and `labels` (Gate logits, class slot 0). See `gate-v2-contract.json`
for the selected binary's hashes and exact shapes. Image normalization and
antialiased resize must match the evaluation code; model scores are not a
guarantee that a detection is correct.

`scripts/prepare_gate_data.py`, `scripts/convert_gate_coco.py`,
`scripts/train_gate.py`, `scripts/audit_split_similarity.py`, and
`scripts/evaluate_gate.py` document the reproducible pipeline. Hardware,
dependency versions, split limitations, and final metrics must accompany any
public performance claim.
