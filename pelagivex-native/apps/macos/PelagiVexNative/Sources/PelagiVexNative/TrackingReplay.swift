#if os(macOS)
import Dispatch
import Foundation
import VisionCore

/// Replays only cached observed boxes. Aliases are an explicitly supplied physical identity.
/// No depth, prototypes, masks, learned re-identification or future observations enter tracking.
enum TrackingReplay {
    private struct LegacyTracker {
        var previous: [Detection] = []
        var nextID = 1
        var lastTime = 0.0

        mutating func update(_ items: [Detection], time: Double) -> [Detection] {
            if time - lastTime > 0.5 || time < lastTime { previous = [] }
            var used = Set<Int>()
            let output = items.map { observation in
                var item = observation
                let match = previous.enumerated()
                    .filter { !used.contains($0.offset) && $0.element.classID == item.classID }
                    .max { $0.element.box.iou(item.box) < $1.element.box.iou(item.box) }
                if let match, match.element.box.iou(item.box) >= 0.3 {
                    used.insert(match.offset)
                    item.trackID = match.element.trackID
                } else {
                    item.trackID = nextID
                    nextID = nextID == 1_000_000 ? 1 : nextID + 1
                }
                return item
            }
            previous = output
            lastTime = time
            return output
        }
    }

    private struct Row {
        let time: Double
        let originalID: Int?
        let legacyID: Int?
        let updatedID: Int?
        let retainedID: Int?
    }

    private struct Gap {
        let previousObservation: Double
        let firstMissing: Double
        let recovery: Double
        let missingFrames: Int
    }

    static func run(trace: PairTrace, aliases: [Int]) throws -> String {
        guard !trace.frames.isEmpty, !aliases.isEmpty, Set(aliases).count == aliases.count,
              aliases.allSatisfy({ $0 > 0 }) else {
            throw PipelineError.invalid("Provide a nonempty trace and distinct positive original track aliases.")
        }
        let aliasSet = Set(aliases)
        let names = Array(Set(trace.frames.flatMap { $0.detections.map(\.name) })).sorted()
        let classIDs = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        var seenAliases = Set<Int>()
        var lastTime = -Double.infinity
        var prepared: [(PairTraceFrame, [Detection], Int?)] = []
        for frame in trace.frames {
            guard frame.time.isFinite, frame.time >= 0, frame.time > lastTime else {
                throw PipelineError.invalid("Tracking replay needs strictly increasing finite nonnegative frame times.")
            }
            lastTime = frame.time
            guard Set(frame.detections.map(\.id)).count == frame.detections.count else {
                throw PipelineError.invalid("A frame contains duplicate original track IDs.")
            }
            let indices = frame.detections.indices.filter { aliasSet.contains(frame.detections[$0].id) }
            guard indices.count <= 1 else {
                throw PipelineError.invalid("Two aliases appear in the same frame; the alias group is not an unambiguous physical identity.")
            }
            let observations = try frame.detections.map { entry -> Detection in
                guard entry.id > 0, !entry.name.isEmpty, entry.score.isFinite, (0...1).contains(entry.score),
                      entry.box.count == 4, entry.box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw PipelineError.invalid("Observed detections need positive IDs, valid classes/scores and normalized four-coordinate boxes.")
                }
                let box = Box(entry.box[0], entry.box[1], entry.box[2], entry.box[3])
                guard box.valid, let classID = classIDs[entry.name] else {
                    throw PipelineError.invalid("Observed detection box has no positive area.")
                }
                return Detection(classID: classID, score: entry.score, box: box, coefficients: [])
            }
            if let index = indices.first {
                seenAliases.insert(frame.detections[index].id)
                // Existing traces do not have observation keys other than original IDs.
                // Reject identical observations rather than silently attributing a subset output.
                guard observations.filter({ sameObservation($0, observations[index]) }).count == 1 else {
                    throw PipelineError.invalid("The selected alias has an indistinguishable duplicate observed box.")
                }
            }
            prepared.append((frame, observations, indices.first))
        }
        guard seenAliases == aliasSet else {
            let missing = aliasSet.subtracting(seenAliases).sorted().map(String.init).joined(separator: ", ")
            throw PipelineError.invalid("Requested aliases are absent from the trace: " + missing)
        }

        var legacy = LegacyTracker()
        let updated = Tracker()
        var legacyNS: [UInt64] = [], updatedNS: [UInt64] = []
        var rows: [Row] = [], gaps: [Gap] = []
        var lastObservedTime: Double?
        var firstMissing: Double?
        var missingFrames = 0
        var lastUpdatedID: Int?
        for (frame, observations, aliasIndex) in prepared {
            let beforeLegacy = DispatchTime.now().uptimeNanoseconds
            let legacyOutput = legacy.update(observations, time: frame.time)
            legacyNS.append(DispatchTime.now().uptimeNanoseconds - beforeLegacy)
            let beforeUpdated = DispatchTime.now().uptimeNanoseconds
            let updatedOutput = updated.update(observations, time: frame.time, newTrackThreshold: 0.25)
            updatedNS.append(DispatchTime.now().uptimeNanoseconds - beforeUpdated)

            let originalID = aliasIndex.map { frame.detections[$0].id }
            let oldID = aliasIndex.map { legacyOutput[$0].trackID }
            let newID = aliasIndex.flatMap { index in
                updatedOutput.first(where: { sameObservation($0, observations[index]) })?.trackID
            }
            if let newID { lastUpdatedID = newID }
            let retainedID = lastUpdatedID.flatMap { id in
                updated.snapshots.contains(where: { $0.id == id && !$0.isObserved }) ? id : nil
            }
            rows.append(Row(time: frame.time, originalID: originalID, legacyID: oldID,
                            updatedID: newID, retainedID: retainedID))
            if aliasIndex != nil {
                if let prior = lastObservedTime, let missingAt = firstMissing {
                    gaps.append(Gap(previousObservation: prior, firstMissing: missingAt,
                                    recovery: frame.time, missingFrames: missingFrames))
                }
                lastObservedTime = frame.time
                firstMissing = nil
                missingFrames = 0
            } else if lastObservedTime != nil {
                if firstMissing == nil { firstMissing = frame.time }
                missingFrames += 1
            }
        }

        let cached = rows.compactMap(\.originalID)
        let originalIDs = rows.map(\.originalID)
        let oldIDs = rows.map(\.legacyID)
        let newIDs = rows.map(\.updatedID)
        let observedFrames = cached.count
        let table = rows.map { row in
            let status: String
            if row.updatedID != nil {
                status = "Observed now"
            } else if let id = row.retainedID {
                status = "Not observed; metadata retained #" + String(id)
            } else {
                status = row.originalID == nil ? "No alias observation" : "Below new-track threshold; not accepted"
            }
            return "| " + [seconds(row.time), display(row.originalID), display(row.legacyID),
                          display(row.updatedID), status].joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        let gapRows = gaps.map {
            "| " + [seconds($0.previousObservation), seconds($0.firstMissing), seconds($0.recovery),
                    String($0.missingFrames), seconds($0.recovery - $0.previousObservation),
                    seconds($0.recovery - $0.firstMissing)].joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        let trailing = firstMissing.map {
            "The alias is absent from sampled detections from \(seconds($0)) s through trace end; no later recovery was observed."
        } ?? "No trailing absence follows the last alias observation."
        let lowCount = prepared.reduce(0) { $0 + $1.1.filter { $0.score < 0.25 }.count }

        return """
        # Cached-observation tracking replay

        Source: \(singleLine(trace.source))

        The caller explicitly identifies original IDs \(aliases.sorted().map(String.init).joined(separator: ", ")) as one physical target. This manual mapping is the only identity reference. All \(trace.frames.count) sampled frames and all their observed detections enter both trackers in the same order. Class names are mapped to shared integer labels; normalized boxes and raw scores are unchanged. Mask coefficients are empty and no model, depth worker or image processing is run.

        | Metric for the supplied physical alias group | Original cached IDs | Legacy one-frame tracker | Updated tracker |
        | --- | ---: | ---: | ---: |
        | Observed / accepted alias frames | \(observedFrames) | \(oldIDs.compactMap { $0 }.count) | \(newIDs.compactMap { $0 }.count) |
        | Distinct assigned IDs | \(Set(cached).count) | \(Set(oldIDs.compactMap { $0 }).count) | \(Set(newIDs.compactMap { $0 }).count) |
        | Assigned-ID changes between successive accepted alias observations | \(changes(originalIDs)) | \(changes(oldIDs)) | \(changes(newIDs)) |
        | Retained metadata frames while alias is not observed | — | 0 | \(rows.filter { $0.originalID == nil && $0.retainedID != nil }.count) |

        | Tracking CPU timing for all scene detections | Legacy | Updated |
        | --- | ---: | ---: |
        | Calls | \(legacyNS.count) | \(updatedNS.count) |
        | Total (ms) | \(milliseconds(legacyNS)) | \(milliseconds(updatedNS)) |
        | Mean per frame (µs) | \(microsecondsMean(legacyNS)) | \(microsecondsMean(updatedNS)) |
        | P95 per frame (µs) | \(microsecondsP95(legacyNS)) | \(microsecondsP95(updatedNS)) |

        | Last observation (s) | First absent sampled frame (s) | Recovery (s) | Absent frames | Observation-to-recovery gap (s) | Sampled absence-to-recovery span (s) |
        | ---: | ---: | ---: | ---: | ---: | ---: |
        \(gapRows.isEmpty ? "| — | — | — | 0 | — | — |" : gapRows)

        \(trailing)

        | Frame time (s) | Original alias ID | Legacy current ID | Updated current ID | Updated state |
        | ---: | ---: | ---: | ---: | --- |
        \(table)

        The legacy implementation reproduces last-frame class-strict greedy IoU association at threshold 0.3, forgetting missed detections immediately and clearing history across a capture gap over 0.5 s. Updated tracking uses the app's Tracker, with 0.8 s metadata retention and new-track threshold 0.25. An ID change is counted across successive accepted observations even when sampled gaps intervene; unassigned observations do not count as a new identity.

        Limitations: original IDs are not treated as ground truth for other objects. This does not measure scene-wide IDF1/HOTA, correctness of re-identification, or detection recall. A reused ID can still be a wrong match; the row table supports manual inspection. Existing traces already discarded weak and missing detections, so this replay cannot test the new decoder's lower-confidence recall or class-alternative support (the trace has no alternatives). There are \(lowCount) cached observations below the updated 0.25 new-track threshold. Retained metadata is not a current observation and does not synthesize a current mask or depth. A sampling interval is not a precise camera dropout duration. CPU timings are local wall-clock durations around tracking calls, include all scene detections and snapshot bookkeeping, and exclude reconstruction, report generation, capture, models and rendering; concurrent Mac workloads and first-call allocation affect them.
        """
    }

    private static func sameObservation(_ lhs: Detection, _ rhs: Detection) -> Bool {
        lhs.classID == rhs.classID && lhs.score == rhs.score && lhs.box == rhs.box
    }

    private static func changes(_ ids: [Int?]) -> Int {
        let observed = ids.compactMap { $0 }
        return zip(observed, observed.dropFirst()).filter { $0 != $1 }.count
    }

    private static func display(_ id: Int?) -> String { id.map(String.init) ?? "—" }
    private static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
    }
    private static func milliseconds(_ values: [UInt64]) -> String {
        String(format: "%.3f", values.reduce(0.0) { $0 + Double($1) } / 1_000_000)
    }
    private static func microsecondsMean(_ values: [UInt64]) -> String {
        String(format: "%.3f", values.reduce(0.0) { $0 + Double($1) } / Double(values.count) / 1_000)
    }
    private static func microsecondsP95(_ values: [UInt64]) -> String {
        let ordered = values.sorted()
        let index = max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)
        return String(format: "%.3f", Double(ordered[index]) / 1_000)
    }
}
#endif
