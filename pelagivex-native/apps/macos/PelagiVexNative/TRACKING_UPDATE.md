# Preview 0.3: detection confidence and continuity

## Changes

The original tracker overwrote its entire history every frame. A single missed detection therefore destroyed the ID. The live detector also filtered below 35% and returned at most 25 targets.

The live application now decodes candidates from 10%, with up to 100 detections. It requires 25% by default to start a new track; a UI slider adjusts that birth threshold from 15% to 70%. Lower-confidence observations can continue an existing track. Two-stage one-to-one global matching uses predicted motion, size, overlap and class compatibility. A high-overlap label change can retain identity when a top alternative in either adjacent observation supports the other class at 10% or more; this is an association heuristic, not class verification.

The tracker remembers missing objects for up to 0.8 seconds. UI rows use track IDs instead of array offsets, so changing score order no longer changes row identity. Missing rows show the last confidence and time since observation, with no current depth. Their old mask coefficients never enter the current frame's masks or depth calculations. Camera rendering reserves colors through brief gaps and supports the expanded target count. Per-row Set A / Set B buttons avoid a frequently changing picker menu.

The display shows the top model class score and two alternatives, without normalizing them into a categorical probability distribution. Confidence is an uncalibrated model output. The model is still YOLO11x-seg with 80 categories; increasing recall does not create an open-vocabulary recognizer.

## Verification

The build runs 40 Swift tests, including low-confidence continuation, missed-frame recovery, expiry, bounded motion prediction, reordered same-class targets, unique assignment, distant newcomers, supported label changes, invalid clocks, raw alternative scores and 60 objects in a decoded scene. Source-frame masks remain separate from retained metadata. Historical pair-policy replays remain byte-identical to their saved Markdown results; --pair-trace keeps the legacy input pipeline deliberately.

The recorded Crowd3 example was manually inspected by clothing. The brown-sweater person is cached ID27 before occlusion, and ID45 after. At 6.904 seconds the person is observed, is absent at sampled 7.004 and 7.105, and returns at 7.306: a 0.402-second observation gap. The old tracker assigns a new ID; updated tracking recovers its original ID. Through 10.590 seconds, 62 observed frames use two legacy IDs and one updated ID.

**Reference limit:** after 10.590 seconds the brown person leaves and cached ID45 moves onto a different gray-sweater person. The old ID is therefore not an identity ground truth for the rest of the recording. The verification window ends before that transition. This is one local recovery check, not a scene-wide IDF1/HOTA or recall benchmark. Cached inputs already excluded weak detections, so this check isolates tracking and cannot measure the lower threshold's detection recall. CPU timing in the report measures all scene-tracking calls only; it is not neural inference time.

## Repeat

Run from the repository root:

```bash
python3 - <<'PY'
import json
from pathlib import Path
root = Path('.cache/pair-study/bonn-crowd3')
trace = json.loads((root / 'trace.json').read_text())
trace['frames'] = [frame for frame in trace['frames'] if frame['time'] <= 10.600]
trace['source'] += '; brown-sweater alias27/45 audit restricted to <=10.600 s (last RGB at 10.590 s), before original ID45 changes physical person'
(root / 'brown-verified-window.json').write_text(json.dumps(trace, indent=2, sort_keys=True) + '\n')
PY
native=pelagivex-native/apps/macos/PelagiVexNative
bash "$native/scripts/build.sh"
"$native/dist/PelagiVex.app/Contents/MacOS/PelagiVexNative" \
  --tracking-replay .cache/pair-study/bonn-crowd3/brown-verified-window.json 27,45
```

This diagnostic runs both trackers on identical boxes, scores, categories and timestamps. No masks, detector or depth model are run during tracking replay. Its physical alias mapping is supplied by the caller and must be checked against the RGB video.

Saved output: [tracking-crowd3-verified.md](tracking-crowd3-verified.md). Local CPU timing fluctuates; the identity counts and the recovery event are the reproducible part of this small check.

## Camo smoke test, 2026-11-07

The final packaged Preview 0.3 was opened with Camo Camera at 1920×1080. The UI showed 9–11 observed objects and, in one observation, a retained gray row with last confidence and last-seen age. Winning and alternative class confidences were visible. The threshold control changed from 25% to 20% and was restored to 25%. Per-row buttons selected bottle #5 as A and chair #7 as B, and a new depth request produced “A is closer”. Observed detector/display throughput was approximately 24–29 FPS while capture was 30 FPS. These are momentary UI measurements, not a long-run throughput or detection-accuracy benchmark. No camera frames were saved.
