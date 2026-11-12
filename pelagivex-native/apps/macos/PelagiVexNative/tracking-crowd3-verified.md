# Cached-observation tracking replay

Source: Bonn RGB-D Dynamic Dataset, Crowd3 (Palazzolo et al., IROS 2019); brown-sweater alias27/45 audit restricted to <=10.600 s (last RGB at 10.590 s), before original ID45 changes physical person

The caller explicitly identifies original IDs 27, 45 as one physical target. This manual mapping is the only identity reference. All 103 sampled frames and all their observed detections enter both trackers in the same order. Class names are mapped to shared integer labels; normalized boxes and raw scores are unchanged. Mask coefficients are empty and no model, depth worker or image processing is run.

| Metric for the supplied physical alias group | Original cached IDs | Legacy one-frame tracker | Updated tracker |
| --- | ---: | ---: | ---: |
| Observed / accepted alias frames | 62 | 62 | 62 |
| Distinct assigned IDs | 2 | 2 | 1 |
| Assigned-ID changes between successive accepted alias observations | 1 | 1 | 0 |
| Retained metadata frames while alias is not observed | — | 0 | 2 |

| Tracking CPU timing for all scene detections | Legacy | Updated |
| --- | ---: | ---: |
| Calls | 103 | 103 |
| Total (ms) | 0.107 | 0.565 |
| Mean per frame (µs) | 1.040 | 5.483 |
| P95 per frame (µs) | 2.041 | 9.542 |

| Last observation (s) | First absent sampled frame (s) | Recovery (s) | Absent frames | Observation-to-recovery gap (s) | Sampled absence-to-recovery span (s) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 6.904 | 7.004 | 7.306 | 2 | 0.402 | 0.301 |

No trailing absence follows the last alias observation.

| Frame time (s) | Original alias ID | Legacy current ID | Updated current ID | Updated state |
| ---: | ---: | ---: | ---: | --- |
| 0.100 | — | — | — | No alias observation |
| 0.401 | — | — | — | No alias observation |
| 0.502 | — | — | — | No alias observation |
| 0.603 | — | — | — | No alias observation |
| 0.703 | — | — | — | No alias observation |
| 0.804 | — | — | — | No alias observation |
| 0.904 | — | — | — | No alias observation |
| 1.005 | — | — | — | No alias observation |
| 1.105 | — | — | — | No alias observation |
| 1.206 | — | — | — | No alias observation |
| 1.307 | — | — | — | No alias observation |
| 1.408 | — | — | — | No alias observation |
| 1.508 | — | — | — | No alias observation |
| 1.609 | — | — | — | No alias observation |
| 1.710 | — | — | — | No alias observation |
| 1.810 | — | — | — | No alias observation |
| 1.910 | — | — | — | No alias observation |
| 2.011 | — | — | — | No alias observation |
| 2.111 | — | — | — | No alias observation |
| 2.212 | — | — | — | No alias observation |
| 2.312 | — | — | — | No alias observation |
| 2.412 | — | — | — | No alias observation |
| 2.513 | — | — | — | No alias observation |
| 2.613 | — | — | — | No alias observation |
| 2.714 | — | — | — | No alias observation |
| 2.815 | — | — | — | No alias observation |
| 2.915 | — | — | — | No alias observation |
| 3.016 | — | — | — | No alias observation |
| 3.116 | — | — | — | No alias observation |
| 3.217 | — | — | — | No alias observation |
| 3.284 | — | — | — | No alias observation |
| 3.384 | — | — | — | No alias observation |
| 3.485 | — | — | — | No alias observation |
| 3.586 | — | — | — | No alias observation |
| 3.686 | — | — | — | No alias observation |
| 3.787 | — | — | — | No alias observation |
| 3.887 | — | — | — | No alias observation |
| 3.988 | — | — | — | No alias observation |
| 4.088 | — | — | — | No alias observation |
| 4.189 | 27 | 27 | 19 | Observed now |
| 4.290 | 27 | 27 | 19 | Observed now |
| 4.390 | 27 | 27 | 19 | Observed now |
| 4.491 | 27 | 27 | 19 | Observed now |
| 4.591 | 27 | 27 | 19 | Observed now |
| 4.691 | 27 | 27 | 19 | Observed now |
| 4.792 | 27 | 27 | 19 | Observed now |
| 4.892 | 27 | 27 | 19 | Observed now |
| 4.993 | 27 | 27 | 19 | Observed now |
| 5.093 | 27 | 27 | 19 | Observed now |
| 5.194 | 27 | 27 | 19 | Observed now |
| 5.295 | 27 | 27 | 19 | Observed now |
| 5.396 | 27 | 27 | 19 | Observed now |
| 5.496 | 27 | 27 | 19 | Observed now |
| 5.597 | 27 | 27 | 19 | Observed now |
| 5.697 | 27 | 27 | 19 | Observed now |
| 5.798 | 27 | 27 | 19 | Observed now |
| 5.898 | 27 | 27 | 19 | Observed now |
| 5.999 | 27 | 27 | 19 | Observed now |
| 6.099 | 27 | 27 | 19 | Observed now |
| 6.199 | 27 | 27 | 19 | Observed now |
| 6.300 | 27 | 27 | 19 | Observed now |
| 6.401 | 27 | 27 | 19 | Observed now |
| 6.501 | 27 | 27 | 19 | Observed now |
| 6.602 | 27 | 27 | 19 | Observed now |
| 6.702 | 27 | 27 | 19 | Observed now |
| 6.803 | 27 | 27 | 19 | Observed now |
| 6.904 | 27 | 27 | 19 | Observed now |
| 7.004 | — | — | — | Not observed; metadata retained #19 |
| 7.105 | — | — | — | Not observed; metadata retained #19 |
| 7.306 | 45 | 45 | 19 | Observed now |
| 7.406 | 45 | 45 | 19 | Observed now |
| 7.507 | 45 | 45 | 19 | Observed now |
| 7.607 | 45 | 45 | 19 | Observed now |
| 7.708 | 45 | 45 | 19 | Observed now |
| 7.808 | 45 | 45 | 19 | Observed now |
| 7.909 | 45 | 45 | 19 | Observed now |
| 8.009 | 45 | 45 | 19 | Observed now |
| 8.110 | 45 | 45 | 19 | Observed now |
| 8.210 | 45 | 45 | 19 | Observed now |
| 8.311 | 45 | 45 | 19 | Observed now |
| 8.411 | 45 | 45 | 19 | Observed now |
| 8.512 | 45 | 45 | 19 | Observed now |
| 8.613 | 45 | 45 | 19 | Observed now |
| 8.713 | 45 | 45 | 19 | Observed now |
| 8.814 | 45 | 45 | 19 | Observed now |
| 8.915 | 45 | 45 | 19 | Observed now |
| 9.015 | 45 | 45 | 19 | Observed now |
| 9.116 | 45 | 45 | 19 | Observed now |
| 9.216 | 45 | 45 | 19 | Observed now |
| 9.283 | 45 | 45 | 19 | Observed now |
| 9.384 | 45 | 45 | 19 | Observed now |
| 9.485 | 45 | 45 | 19 | Observed now |
| 9.585 | 45 | 45 | 19 | Observed now |
| 9.685 | 45 | 45 | 19 | Observed now |
| 9.786 | 45 | 45 | 19 | Observed now |
| 9.886 | 45 | 45 | 19 | Observed now |
| 9.987 | 45 | 45 | 19 | Observed now |
| 10.088 | 45 | 45 | 19 | Observed now |
| 10.188 | 45 | 45 | 19 | Observed now |
| 10.289 | 45 | 45 | 19 | Observed now |
| 10.389 | 45 | 45 | 19 | Observed now |
| 10.490 | 45 | 45 | 19 | Observed now |
| 10.590 | 45 | 45 | 19 | Observed now |

The legacy implementation reproduces last-frame class-strict greedy IoU association at threshold 0.3, forgetting missed detections immediately and clearing history across a capture gap over 0.5 s. Updated tracking uses the app's Tracker, with 0.8 s metadata retention and new-track threshold 0.25. An ID change is counted across successive accepted observations even when sampled gaps intervene; unassigned observations do not count as a new identity.

Limitations: original IDs are not treated as ground truth for other objects. This does not measure scene-wide IDF1/HOTA, correctness of re-identification, or detection recall. A reused ID can still be a wrong match; the row table supports manual inspection. Existing traces already discarded weak and missing detections, so this replay cannot test the new decoder's lower-confidence recall or class-alternative support (the trace has no alternatives). There are 0 cached observations below the updated 0.25 new-track threshold. Retained metadata is not a current observation and does not synthesize a current mask or depth. A sampling interval is not a precise camera dropout duration. CPU timings are local wall-clock durations around tracking calls, include all scene detections and snapshot bookkeeping, and exclude reconstruction, report generation, capture, models and rendering; concurrent Mac workloads and first-call allocation affect them.
