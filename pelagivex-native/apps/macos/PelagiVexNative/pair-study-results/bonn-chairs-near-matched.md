# Pair depth replay

Replay of Bonn RGB-D Rigid Multi-Body, Chairs (Stückler and Behnke, BMVC 2013) for tracks A #2 and B #1 over 166 frames spanning 16.48 s.
Both selected IDs were visible for 16.48 s; 16.48 s also had reference. Reference: Bonn RGB-D Rigid Multi-Body, Chairs (Stückler and Behnke, BMVC 2013), synchronized sensor depth in independent RGB-only landmarks for left chair seat and right chair seat

| Metric | Five-second baseline | Pilot adaptive | No-hold ablation | Adaptive |
| --- | ---: | ---: | ---: | ---: |
| Accepted depth calls | 8 | 8 | 8 | 8 |
| Worker completions inside trace | 8 | 8 | 8 | 8 |
| Measurements rejected after completion | 0 | 0 | 0 | 0 |
| Modeled worker seconds, including any unfinished last call | 1.19 | 1.18 | 1.18 | 1.18 |
| Calls using fallback duration | 0 | 0 | 0 | 0 |
| Directional coverage of scored time | 37.3% | 20.5% | 33.4% | 34.6% |
| Time showing a wrong direction (s) | 3.78 | 1.10 | 2.92 | 2.92 |
| Time showing the opposite order (s) | 0.80 | 0.00 | 0.00 | 0.00 |
| Time showing a direction inside the reference margin (s) | 2.98 | 1.10 | 2.92 | 2.92 |
| Reference reversals corrected | 0 / 2 | 0 / 2 | 0 / 2 | 1 / 2 |
| Unresolved reference reversals | 2 | 2 | 2 | 1 |
| Median delay of resolved corrections (s) | — | — | — | 0.60 |

| Reference reversal at (s) | New direction | Five-second baseline delay (s) | Pilot adaptive delay (s) | No-hold ablation delay (s) | Adaptive delay (s) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 7.71 | A closer | Unresolved | Unresolved | Unresolved | Unresolved |
| 15.68 | B closer | Unresolved | Unresolved | Unresolved | 0.60 |

- **Five-second baseline:** 0.00 s (initial, 0.14 s worker, bCloser); 2.09 s (interval, 0.15 s worker, tooClose); 4.10 s (interval, 0.15 s worker, tooClose); 6.11 s (interval, 0.15 s worker, tooClose); 8.11 s (interval, 0.15 s worker, tooClose); 10.20 s (interval, 0.15 s worker, tooClose); 12.21 s (interval, 0.15 s worker, aCloser); 14.28 s (interval, 0.15 s worker, aCloser)
- **Pilot adaptive:** 0.00 s (initial, 0.14 s worker, bCloser); 2.09 s (changed, 0.15 s worker, tooClose); 4.10 s (changed, 0.15 s worker, tooClose); 6.01 s (changed, 0.15 s worker, tooClose); 9.09 s (expired, 0.15 s worker, tooClose); 10.40 s (changed, 0.15 s worker, tooClose); 12.01 s (changed, 0.15 s worker, aCloser); 14.18 s (changed, 0.15 s worker, aCloser)
- **No-hold ablation:** 0.00 s (initial, 0.14 s worker, bCloser); 2.89 s (interval, 0.15 s worker, tooClose); 4.10 s (interval, 0.15 s worker, tooClose); 6.01 s (interval, 0.15 s worker, tooClose); 8.01 s (interval, 0.15 s worker, tooClose); 10.10 s (interval, 0.15 s worker, tooClose); 12.01 s (interval, 0.15 s worker, aCloser); 14.78 s (changed, 0.15 s worker, tooClose)
- **Adaptive:** 0.00 s (initial, 0.14 s worker, bCloser); 2.89 s (interval, 0.15 s worker, tooClose); 4.10 s (interval, 0.15 s worker, tooClose); 6.01 s (interval, 0.15 s worker, tooClose); 8.01 s (interval, 0.15 s worker, tooClose); 10.10 s (interval, 0.15 s worker, tooClose); 12.01 s (interval, 0.15 s worker, aCloser); 16.08 s (changed, 0.14 s worker, bCloser)

The baseline refreshes every two seconds when available and can display evidence for up to five seconds. All policies have the same explicit cap of 8 calls. See actual counts above. Pilot adaptive reproduces the first study policy. The ablation uses the new policy without the confirmation wait. The app uses the baseline and the new adaptive policy without an end-of-clip cap.
Replay uses one worker and no queue. A request reads only its submitted RGB frame's estimate, and the result becomes available on the first recorded frame at or after the measured worker finish time. Missing durations use the trace median (0.15 s). Worker timing omits JPEG preparation, IPC, rendering, and capture latency.
Scoring weights each answer by time until the next recorded frame, skipping intervals over 0.5 s. The reference and model both use a margin of 5 cm or 5% of the nearer depth, whichever is greater. “Too close” and rechecking are non-directional answers. Reference depths are used only for scoring.
A reversal requires two adjacent reference frames in the new direction after a confirmed opposite direction. Correction delay is measured from the first of those frames until the answer agrees while the new reference order still holds. A gap, lost reference, change of order, or trace end before correction leaves that reversal unresolved.
