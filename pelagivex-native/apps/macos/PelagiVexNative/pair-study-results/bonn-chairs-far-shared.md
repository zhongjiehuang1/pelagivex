# Pair depth replay

Replay of Bonn RGB-D Rigid Multi-Body, Chairs (Stückler and Behnke, BMVC 2013) for tracks A #1 and B #2 over 142 frames spanning 14.11 s.
Both selected IDs were visible for 14.11 s; 14.11 s also had reference. Reference: Synchronized sensor depth aggregated inside the same predicted instance masks used for monocular estimates.

| Metric | Five-second baseline | Pilot adaptive | No-hold ablation | Adaptive |
| --- | ---: | ---: | ---: | ---: |
| Accepted depth calls | 7 | 7 | 7 | 6 |
| Worker completions inside trace | 7 | 7 | 6 | 5 |
| Measurements rejected after completion | 0 | 0 | 0 | 0 |
| Modeled worker seconds, including any unfinished last call | 1.01 | 1.01 | 1.01 | 0.86 |
| Calls using fallback duration | 0 | 0 | 0 | 0 |
| Directional coverage of scored time | 84.4% | 28.0% | 95.7% | 90.0% |
| Time showing a wrong direction (s) | 0.30 | 0.00 | 0.70 | 0.70 |
| Time showing the opposite order (s) | 0.00 | 0.00 | 0.00 | 0.00 |
| Time showing a direction inside the reference margin (s) | 0.30 | 0.00 | 0.70 | 0.70 |
| Reference reversals corrected | — | — | — | — |
| Unresolved reference reversals | 0 | 0 | 0 | 0 |
| Median delay of resolved corrections (s) | — | — | — | — |

| Reference reversal at (s) | New direction | Five-second baseline delay (s) | Pilot adaptive delay (s) | No-hold ablation delay (s) | Adaptive delay (s) |
| ---: | --- | ---: | ---: | ---: | ---: |
| — | None observed | — | — | — | — |

- **Five-second baseline:** 20.19 s (initial, 0.15 s worker, bCloser); 22.19 s (interval, 0.15 s worker, bCloser); 24.21 s (interval, 0.14 s worker, bCloser); 26.29 s (interval, 0.14 s worker, bCloser); 28.30 s (interval, 0.14 s worker, tooClose); 30.30 s (interval, 0.14 s worker, bCloser); 32.39 s (interval, 0.14 s worker, bCloser)
- **Pilot adaptive:** 20.19 s (initial, 0.15 s worker, bCloser); 22.19 s (changed, 0.15 s worker, bCloser); 24.21 s (changed, 0.14 s worker, bCloser); 26.29 s (changed, 0.14 s worker, bCloser); 28.20 s (changed, 0.14 s worker, tooClose); 30.20 s (changed, 0.14 s worker, bCloser); 32.28 s (changed, 0.15 s worker, bCloser)
- **No-hold ablation:** 20.19 s (initial, 0.15 s worker, bCloser); 22.99 s (interval, 0.14 s worker, bCloser); 25.81 s (interval, 0.14 s worker, bCloser); 28.60 s (interval, 0.14 s worker, bCloser); 30.50 s (changed, 0.14 s worker, bCloser); 31.50 s (changed, 0.14 s worker, bCloser); 34.29 s (interval, 0.15 s worker, worker busy at end of trace)
- **Adaptive:** 20.19 s (initial, 0.15 s worker, bCloser); 22.99 s (interval, 0.14 s worker, bCloser); 25.81 s (interval, 0.14 s worker, bCloser); 28.60 s (interval, 0.14 s worker, bCloser); 31.50 s (changed, 0.14 s worker, bCloser); 34.29 s (interval, 0.15 s worker, worker busy at end of trace)

The baseline refreshes every two seconds when available and can display evidence for up to five seconds. The periodic baseline's 7 calls set the retrospective cap for the other policies. See actual counts above. Pilot adaptive reproduces the first study policy. The ablation uses the new policy without the confirmation wait. The app uses the baseline and the new adaptive policy without an end-of-clip cap.
Replay uses one worker and no queue. A request reads only its submitted RGB frame's estimate, and the result becomes available on the first recorded frame at or after the measured worker finish time. Missing durations use the trace median (0.14 s). Worker timing omits JPEG preparation, IPC, rendering, and capture latency.
Scoring weights each answer by time until the next recorded frame, skipping intervals over 0.5 s. The reference and model both use a margin of 5 cm or 5% of the nearer depth, whichever is greater. “Too close” and rechecking are non-directional answers. Reference depths are used only for scoring.
A reversal requires two adjacent reference frames in the new direction after a confirmed opposite direction. Correction delay is measured from the first of those frames until the answer agrees while the new reference order still holds. A gap, lost reference, change of order, or trace end before correction leaves that reversal unresolved.
