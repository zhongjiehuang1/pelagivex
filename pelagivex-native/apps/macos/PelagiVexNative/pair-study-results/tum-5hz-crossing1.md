# Pair depth replay

Replay of TUM RGB-D SLAM Benchmark, freiburg3_walking_static (Sturm et al., IROS 2012), CC BY 4.0; Voxel51/TUM-RGBD MCAP conversion. for tracks A #1 and B #2 over 122 frames spanning 24.80 s.
Both selected IDs were visible for 7.20 s; 7.20 s also had reference. Reference: Synchronized sensor depth aggregated inside the same predicted instance masks used for monocular estimates.

| Metric | Five-second baseline | Pilot adaptive | No-hold ablation | Adaptive |
| --- | ---: | ---: | ---: | ---: |
| Accepted depth calls | 4 | 4 | 4 | 4 |
| Worker completions inside trace | 4 | 4 | 4 | 4 |
| Measurements rejected after completion | 0 | 0 | 0 | 0 |
| Modeled worker seconds, including any unfinished last call | 0.62 | 0.62 | 0.62 | 0.62 |
| Calls using fallback duration | 0 | 0 | 0 | 0 |
| Directional coverage of scored time | 27.9% | 5.7% | 13.9% | 11.2% |
| Time showing a wrong direction (s) | 0.40 | 0.00 | 0.19 | 0.20 |
| Time showing the opposite order (s) | 0.19 | 0.00 | 0.19 | 0.00 |
| Time showing a direction inside the reference margin (s) | 0.20 | 0.00 | 0.00 | 0.20 |
| Reference reversals corrected | 1 / 2 | 1 / 2 | 1 / 2 | 1 / 2 |
| Unresolved reference reversals | 1 | 1 | 1 | 1 |
| Median delay of resolved corrections (s) | 1.58 | 1.58 | 1.58 | 2.59 |

| Reference reversal at (s) | New direction | Five-second baseline delay (s) | Pilot adaptive delay (s) | No-hold ablation delay (s) | Adaptive delay (s) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 2.81 | A closer | 1.58 | 1.58 | 1.58 | 2.59 |
| 6.21 | B closer | Unresolved | Unresolved | Unresolved | Unresolved |

- **Five-second baseline:** 0.00 s (initial, 0.15 s worker, tooClose); 2.01 s (interval, 0.15 s worker, tooClose); 4.19 s (interval, 0.15 s worker, aCloser); 6.21 s (interval, 0.15 s worker, tooClose)
- **Pilot adaptive:** 0.00 s (initial, 0.15 s worker, tooClose); 2.01 s (changed, 0.15 s worker, tooClose); 4.19 s (changed, 0.15 s worker, aCloser); 6.00 s (changed, 0.15 s worker, aCloser)
- **No-hold ablation:** 0.00 s (initial, 0.15 s worker, tooClose); 2.01 s (interval, 0.15 s worker, tooClose); 4.19 s (changed, 0.15 s worker, aCloser); 6.00 s (changed, 0.15 s worker, aCloser)
- **Adaptive:** 0.00 s (initial, 0.15 s worker, tooClose); 2.01 s (interval, 0.15 s worker, tooClose); 5.19 s (changed, 0.16 s worker, aCloser); 6.80 s (changed, 0.16 s worker, bCloser)

The baseline refreshes every two seconds when available and can display evidence for up to five seconds. The periodic baseline's 4 calls set the retrospective cap for the other policies. See actual counts above. Pilot adaptive reproduces the first study policy. The ablation uses the new policy without the confirmation wait. The app uses the baseline and the new adaptive policy without an end-of-clip cap.
Replay uses one worker and no queue. A request reads only its submitted RGB frame's estimate, and the result becomes available on the first recorded frame at or after the measured worker finish time. Missing durations use the trace median (0.15 s). Worker timing omits JPEG preparation, IPC, rendering, and capture latency.
Scoring weights each answer by time until the next recorded frame, skipping intervals over 0.5 s. The reference and model both use a margin of 5 cm or 5% of the nearer depth, whichever is greater. “Too close” and rechecking are non-directional answers. Reference depths are used only for scoring.
A reversal requires two adjacent reference frames in the new direction after a confirmed opposite direction. Correction delay is measured from the first of those frames until the answer agrees while the new reference order still holds. A gap, lost reference, change of order, or trace end before correction leaves that reversal unresolved.
