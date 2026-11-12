# Pair depth replay

Replay of TUM RGB-D SLAM Benchmark, freiburg3_walking_static (Sturm et al., IROS 2012), CC BY 4.0; Voxel51/TUM-RGBD MCAP conversion. for tracks A #67 and B #92 over 243 frames spanning 24.90 s.
Both selected IDs were visible for 1.71 s; 1.71 s also had reference. Reference: Synchronized sensor depth aggregated inside the same predicted instance masks used for monocular estimates.

| Metric | Five-second baseline | Pilot adaptive | No-hold ablation | Adaptive |
| --- | ---: | ---: | ---: | ---: |
| Accepted depth calls | 1 | 1 | 1 | 1 |
| Worker completions inside trace | 1 | 1 | 1 | 1 |
| Measurements rejected after completion | 0 | 1 | 0 | 0 |
| Modeled worker seconds, including any unfinished last call | 0.16 | 0.16 | 0.16 | 0.16 |
| Calls using fallback duration | 0 | 0 | 0 | 0 |
| Directional coverage of scored time | 87.9% | 0.0% | 0.0% | 0.0% |
| Time showing a wrong direction (s) | 1.20 | 0.00 | 0.00 | 0.00 |
| Time showing the opposite order (s) | 1.00 | 0.00 | 0.00 | 0.00 |
| Time showing a direction inside the reference margin (s) | 0.20 | 0.00 | 0.00 | 0.00 |
| Reference reversals corrected | 0 / 1 | 0 / 1 | 0 / 1 | 0 / 1 |
| Unresolved reference reversals | 1 | 1 | 1 | 1 |
| Median delay of resolved corrections (s) | — | — | — | — |

| Reference reversal at (s) | New direction | Five-second baseline delay (s) | Pilot adaptive delay (s) | No-hold ablation delay (s) | Adaptive delay (s) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 13.91 | B closer | Unresolved | Unresolved | Unresolved | Unresolved |

- **Five-second baseline:** 13.20 s (initial, 0.16 s worker, aCloser)
- **Pilot adaptive:** 13.20 s (gap, 0.16 s worker, stale or invalid)
- **No-hold ablation:** 13.20 s (gap, 0.16 s worker, aCloser)
- **Adaptive:** 13.20 s (gap, 0.16 s worker, aCloser)

The baseline refreshes every two seconds when available and can display evidence for up to five seconds. The periodic baseline's 1 calls set the retrospective cap for the other policies. See actual counts above. Pilot adaptive reproduces the first study policy. The ablation uses the new policy without the confirmation wait. The app uses the baseline and the new adaptive policy without an end-of-clip cap.
Replay uses one worker and no queue. A request reads only its submitted RGB frame's estimate, and the result becomes available on the first recorded frame at or after the measured worker finish time. Missing durations use the trace median (0.16 s). Worker timing omits JPEG preparation, IPC, rendering, and capture latency.
Scoring weights each answer by time until the next recorded frame, skipping intervals over 0.5 s. The reference and model both use a margin of 5 cm or 5% of the nearer depth, whichever is greater. “Too close” and rechecking are non-directional answers. Reference depths are used only for scoring.
A reversal requires two adjacent reference frames in the new direction after a confirmed opposite direction. Correction delay is measured from the first of those frames until the answer agrees while the new reference order still holds. A gap, lost reference, change of order, or trace end before correction leaves that reversal unresolved.
