# Pair depth replay

Replay of Bonn RGB-D Dynamic Dataset, Crowd3 (Palazzolo et al., IROS 2019) for tracks A #27 and B #1 over 112 frames spanning 11.40 s.
Both selected IDs were visible for 2.82 s; 2.82 s also had reference. Reference: Synchronized sensor depth aggregated inside the same predicted instance masks used for monocular estimates.

| Metric | Five-second baseline | Pilot adaptive | No-hold ablation | Adaptive |
| --- | ---: | ---: | ---: | ---: |
| Accepted depth calls | 2 | 2 | 2 | 2 |
| Worker completions inside trace | 2 | 2 | 2 | 2 |
| Measurements rejected after completion | 0 | 1 | 1 | 1 |
| Modeled worker seconds, including any unfinished last call | 0.29 | 0.29 | 0.29 | 0.29 |
| Calls using fallback duration | 0 | 0 | 0 | 0 |
| Directional coverage of scored time | 71.4% | 0.0% | 3.6% | 53.6% |
| Time showing a wrong direction (s) | 1.81 | 0.00 | 0.00 | 1.51 |
| Time showing the opposite order (s) | 0.70 | 0.00 | 0.00 | 0.40 |
| Time showing a direction inside the reference margin (s) | 1.11 | 0.00 | 0.00 | 1.11 |
| Reference reversals corrected | 1 / 1 | 0 / 1 | 0 / 1 | 0 / 1 |
| Unresolved reference reversals | 0 | 1 | 1 | 1 |
| Median delay of resolved corrections (s) | 0.00 | — | — | — |

| Reference reversal at (s) | New direction | Five-second baseline delay (s) | Pilot adaptive delay (s) | No-hold ablation delay (s) | Adaptive delay (s) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 6.20 | B closer | 0.00 | Unresolved | Unresolved | Unresolved |

- **Five-second baseline:** 4.19 s (initial, 0.14 s worker, bCloser); 6.20 s (interval, 0.15 s worker, tooClose)
- **Pilot adaptive:** 4.19 s (gap, 0.14 s worker, stale or invalid); 4.69 s (changed, 0.14 s worker, aCloser)
- **No-hold ablation:** 4.19 s (gap, 0.14 s worker, stale or invalid); 4.69 s (changed, 0.14 s worker, aCloser)
- **Adaptive:** 4.19 s (gap, 0.14 s worker, stale or invalid); 4.89 s (changed, 0.14 s worker, aCloser)

The baseline refreshes every two seconds when available and can display evidence for up to five seconds. The periodic baseline's 2 calls set the retrospective cap for the other policies. See actual counts above. Pilot adaptive reproduces the first study policy. The ablation uses the new policy without the confirmation wait. The app uses the baseline and the new adaptive policy without an end-of-clip cap.
Replay uses one worker and no queue. A request reads only its submitted RGB frame's estimate, and the result becomes available on the first recorded frame at or after the measured worker finish time. Missing durations use the trace median (0.15 s). Worker timing omits JPEG preparation, IPC, rendering, and capture latency.
Scoring weights each answer by time until the next recorded frame, skipping intervals over 0.5 s. The reference and model both use a margin of 5 cm or 5% of the nearer depth, whichever is greater. “Too close” and rechecking are non-directional answers. Reference depths are used only for scoring.
A reversal requires two adjacent reference frames in the new direction after a confirmed opposite direction. Correction delay is measured from the first of those frames until the answer agrees while the new reference order still holds. A gap, lost reference, change of order, or trace end before correction leaves that reversal unresolved.
