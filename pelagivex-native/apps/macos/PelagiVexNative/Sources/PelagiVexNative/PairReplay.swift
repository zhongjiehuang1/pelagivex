#if os(macOS)
import Foundation
import VisionCore

struct PairIndependentReference: Decodable {
    struct Frame: Decodable {
        let time: Double
        let depthA: Double?
        let depthB: Double?
    }
    let source: String
    let trackA: Int
    let trackB: Int
    let frames: [Frame]
}

enum PairReplay {
    // Do not extrapolate a sampled frame across a capture gap.
    private static let maximumScoredInterval = 0.5

    private struct Frame {
        let time: Double
        let geometry: PairGeometry?
        let estimates: (Double, Double)?
        let reference: PairOrdering?
        let depthSeconds: Double?
    }

    private struct Pending {
        let request: PairRequest
        let result: PairMeasurement?
        let readyAt: Double
    }

    private struct Call {
        let time: Double
        let reason: PairRisk
        let duration: Double
        var outcome = "worker busy at end of trace"
    }

    private struct Run {
        var history: [Call] = []
        var calls: Int { history.count }
        var completed = 0
        var modelSeconds = 0.0
        var discardedMeasurements = 0
        var fallbackCalls = 0
        var answers: [PairOrdering?] = []
    }

    private struct Reversal {
        let time: Double
        let direction: PairOrdering
        let delay: Double?
    }

    private struct Scores {
        var visibleSeconds = 0.0
        var scoredSeconds = 0.0
        var answeredSeconds = 0.0
        var wrongSeconds = 0.0
        var reversedSeconds = 0.0
        var falseDirectionSeconds = 0.0
        var reversals: [Reversal] = []
        var corrections: [Double] { reversals.compactMap(\.delay) }
        var unresolved: Int { reversals.count - corrections.count }
    }

    static func run(trace: PairTrace, a: Int, b: Int, reference: PairIndependentReference? = nil,
                    cap: Int? = nil) throws -> String {
        guard let selection = PairSelection(a, b) else {
            throw PipelineError.invalid("Replay requires two different track IDs.")
        }
        guard trace.frames.count >= 2 else {
            throw PipelineError.invalid("Replay requires at least two trace frames.")
        }
        var labelledTimes: [Double: PairIndependentReference.Frame]?
        if let reference {
            guard reference.trackA == a, reference.trackB == b, !reference.frames.isEmpty else {
                throw PipelineError.invalid("Independent reference requires matching A and B track IDs and labelled frames.")
            }
            let traceTimes = Set(trace.frames.map(\.time))
            var labels: [Double: PairIndependentReference.Frame] = [:]
            for frame in reference.frames {
                guard traceTimes.contains(frame.time), labels.updateValue(frame, forKey: frame.time) == nil else {
                    throw PipelineError.invalid("Each independent reference time must exactly match a unique trace frame.")
                }
            }
            labelledTimes = labels
        }
        let frames = try trace.frames.map { try makeFrame($0, selection: selection, labelledTimes: labelledTimes) }
        guard zip(frames, frames.dropFirst()).allSatisfy({ $0.time < $1.time }) else {
            throw PipelineError.invalid("Trace frame times must be strictly increasing.")
        }
        guard let fallback = median(frames.compactMap(\.depthSeconds)) else {
            throw PipelineError.invalid("Trace has no positive measured depth durations.")
        }

        let baseline = simulate(frames, selection: selection, mode: .baseline, cap: cap, fallback: fallback)
        let runs = [baseline] + [PairMode.pilotAdaptive, .adaptiveImmediate, .adaptive].map {
            simulate(frames, selection: selection, mode: $0, cap: cap ?? baseline.calls, fallback: fallback)
        }
        let scores = runs.map { score(frames, answers: $0.answers) }
        let baselineScores = scores[0]
        let source = trace.source.split(whereSeparator: \.isNewline).joined(separator: " ")
        let span = frames[frames.count - 1].time - frames[0].time
        let reversalRows = baselineScores.reversals.enumerated().map { index, event in
            let direction = event.direction == .aCloser ? "A closer" : "B closer"
            let delays = scores.map { $0.reversals[index].delay.map(seconds) ?? "Unresolved" }
            return row([seconds(event.time), direction] + delays)
        }.joined(separator: "\n")
        let names = ["Five-second baseline", "Pilot adaptive", "No-hold ablation", "Adaptive"]
        let histories = zip(names, runs).map { name, run in
            let details = run.history.map {
                "\(seconds($0.time)) s (\($0.reason.rawValue), \(seconds($0.duration)) s worker, \($0.outcome))"
            }
            return "- **\(name):** " + (details.isEmpty ? "no calls" : details.joined(separator: "; "))
        }.joined(separator: "\n")
        func counts(_ keyPath: KeyPath<Run, Int>) -> [String] {
            runs.map { String($0[keyPath: keyPath]) }
        }
        let referenceName = reference?.source.split(whereSeparator: \.isNewline).joined(separator: " ")
            ?? "Synchronized sensor depth aggregated inside the same predicted instance masks used for monocular estimates."
        let budget = cap.map { "All policies have the same explicit cap of \($0) calls." } ??
            "The periodic baseline's \(baseline.calls) calls set the retrospective cap for the other policies."

        return """
        # Pair depth replay

        Replay of \(source) for tracks A #\(a) and B #\(b) over \(frames.count) frames spanning \(seconds(span)) s.
        Both selected IDs were visible for \(seconds(baselineScores.visibleSeconds)) s; \(seconds(baselineScores.scoredSeconds)) s also had reference. Reference: \(referenceName)

        \(row(["Metric"] + names))
        | --- | ---: | ---: | ---: | ---: |
        \(row(["Accepted depth calls"] + counts(\.calls)))
        \(row(["Worker completions inside trace"] + counts(\.completed)))
        \(row(["Measurements rejected after completion"] + counts(\.discardedMeasurements)))
        \(row(["Modeled worker seconds, including any unfinished last call"] + runs.map { seconds($0.modelSeconds) }))
        \(row(["Calls using fallback duration"] + counts(\.fallbackCalls)))
        \(row(["Directional coverage of scored time"] + scores.map(coverage)))
        \(row(["Time showing a wrong direction (s)"] + scores.map { scoredTime($0.wrongSeconds, $0) }))
        \(row(["Time showing the opposite order (s)"] + scores.map { scoredTime($0.reversedSeconds, $0) }))
        \(row(["Time showing a direction inside the reference margin (s)"] + scores.map { scoredTime($0.falseDirectionSeconds, $0) }))
        \(row(["Reference reversals corrected"] + scores.map(correctionCount)))
        \(row(["Unresolved reference reversals"] + scores.map { String($0.unresolved) }))
        \(row(["Median delay of resolved corrections (s)"] + scores.map { median($0.corrections).map(seconds) ?? "—" }))

        \(row(["Reference reversal at (s)", "New direction"] + names.map { $0 + " delay (s)" }))
        | ---: | --- | ---: | ---: | ---: | ---: |
        \(reversalRows.isEmpty ? "| — | None observed | — | — | — | — |" : reversalRows)

        \(histories)

        The baseline refreshes every two seconds when available and can display evidence for up to five seconds. \(budget) See actual counts above. Pilot adaptive reproduces the first study policy. The ablation uses the new policy without the confirmation wait. The app uses the baseline and the new adaptive policy without an end-of-clip cap.
        Replay uses one worker and no queue. A request reads only its submitted RGB frame's estimate, and the result becomes available on the first recorded frame at or after the measured worker finish time. Missing durations use the trace median (\(seconds(fallback)) s). Worker timing omits JPEG preparation, IPC, rendering, and capture latency.
        Scoring weights each answer by time until the next recorded frame, skipping intervals over 0.5 s. The reference and model both use a margin of 5 cm or 5% of the nearer depth, whichever is greater. “Too close” and rechecking are non-directional answers. Reference depths are used only for scoring.
        A reversal requires two adjacent reference frames in the new direction after a confirmed opposite direction. Correction delay is measured from the first of those frames until the answer agrees while the new reference order still holds. A gap, lost reference, change of order, or trace end before correction leaves that reversal unresolved.
        """
    }

    private static func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }

    private static func makeFrame(_ frame: PairTraceFrame, selection: PairSelection,
                                  labelledTimes: [Double: PairIndependentReference.Frame]?) throws -> Frame {
        guard frame.time.isFinite, frame.time >= 0 else {
            throw PipelineError.invalid("Trace frame time must be finite and nonnegative.")
        }
        let tracksA = frame.detections.filter { $0.id == selection.a }
        let tracksB = frame.detections.filter { $0.id == selection.b }
        guard tracksA.count < 2, tracksB.count < 2 else {
            throw PipelineError.invalid("Trace contains duplicate selected track IDs in a frame.")
        }
        let duration = positive(frame.depthSeconds)
        guard let a = tracksA.first, let b = tracksB.first else {
            return Frame(time: frame.time, geometry: nil, estimates: nil, reference: nil, depthSeconds: duration)
        }
        let geometry = try PairGeometry(selection: selection, received: frame.time, boxA: box(a.box), boxB: box(b.box))
        let estimates = positive(a.depth).flatMap { first in positive(b.depth).map { (first, $0) } }
        let reference: PairOrdering?
        if let labelledTimes {
            let label = labelledTimes[frame.time]
            reference = positive(label?.depthA).flatMap { first in positive(label?.depthB).map { ordering(first, $0) } }
        } else {
            reference = positive(a.reference).flatMap { first in positive(b.reference).map { ordering(first, $0) } }
        }
        return Frame(time: frame.time, geometry: geometry, estimates: estimates, reference: reference, depthSeconds: duration)
    }

    private static func box(_ values: [Float]) throws -> Box {
        guard values.count == 4, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw PipelineError.invalid("Trace boxes must contain four normalized source coordinates.")
        }
        let result = Box(values[0], values[1], values[2], values[3])
        guard result.valid else { throw PipelineError.invalid("Trace box must have positive width and height.") }
        return result
    }

    private static func simulate(_ frames: [Frame], selection: PairSelection, mode: PairMode, cap: Int?, fallback: Double) -> Run {
        var run = Run()
        var policy = PairPolicy(mode: mode)
        var pending: Pending?
        for frame in frames {
            if let ready = pending, ready.readyAt <= frame.time {
                if let result = ready.result {
                    if policy.complete(result) {
                        run.history[run.history.count - 1].outcome = result.ordering?.rawValue ?? "invalid depth"
                    } else {
                        run.discardedMeasurements += 1
                        run.history[run.history.count - 1].outcome = "stale or invalid"
                    }
                } else {
                    policy.fail(ready.request)
                    run.history[run.history.count - 1].outcome = "no paired measurement"
                }
                pending = nil
                run.completed += 1
            }

            let decision = policy.update(selection: selection, geometry: frame.geometry, now: frame.time)
            run.answers.append(decision.ordering)
            guard pending == nil, run.calls < (cap ?? Int.max), let request = decision.request,
                  policy.markSubmitted(request) else { continue }
            let duration = frame.depthSeconds ?? fallback
            let result = frame.estimates.map { PairMeasurement(request: request, depthA: $0.0, depthB: $0.1) }
            pending = Pending(request: request, result: result, readyAt: frame.time + duration)
            run.history.append(Call(time: frame.time, reason: request.reason, duration: duration))
            run.modelSeconds += duration
            if frame.depthSeconds == nil { run.fallbackCalls += 1 }
        }
        return run
    }

    private static func score(_ frames: [Frame], answers: [PairOrdering?]) -> Scores {
        var scores = Scores()
        for index in frames.indices.dropLast() {
            let duration = frames[index + 1].time - frames[index].time
            guard duration <= maximumScoredInterval, frames[index].geometry != nil else { continue }
            scores.visibleSeconds += duration
            guard let reference = frames[index].reference else { continue }
            scores.scoredSeconds += duration
            guard let answer = answers[index], answer != .tooClose else { continue }
            scores.answeredSeconds += duration
            guard answer != reference else { continue }
            scores.wrongSeconds += duration
            if reference == .tooClose {
                scores.falseDirectionSeconds += duration
            } else {
                scores.reversedSeconds += duration
            }
        }

        var previousDirection: PairOrdering?
        for index in frames.indices.dropLast() {
            if index > 0, frames[index].time - frames[index - 1].time > maximumScoredInterval {
                previousDirection = nil
            }
            guard let direction = frames[index].reference else {
                previousDirection = nil
                continue
            }
            guard direction != .tooClose, frames[index + 1].reference == direction,
                  frames[index + 1].time - frames[index].time <= maximumScoredInterval else { continue }
            if let previousDirection, direction != previousDirection {
                let delay = correctionDelay(frames, answers: answers, start: index, direction: direction)
                scores.reversals.append(Reversal(time: frames[index].time, direction: direction, delay: delay))
            }
            previousDirection = direction
        }
        return scores
    }

    private static func correctionDelay(_ frames: [Frame], answers: [PairOrdering?], start: Int, direction: PairOrdering) -> Double? {
        for index in start..<frames.count {
            if index > start, frames[index].time - frames[index - 1].time > maximumScoredInterval { break }
            guard frames[index].reference == direction else { break }
            if answers[index] == direction { return frames[index].time - frames[start].time }
        }
        return nil
    }

    // Keep this calculation aligned with PairMeasurement.ordering in VisionCore.
    private static func ordering(_ a: Double, _ b: Double) -> PairOrdering {
        let margin = max(0.05, 0.05 * min(a, b))
        if abs(a - b) <= margin + 1e-12 { return .tooClose }
        return a < b ? .aCloser : .bCloser
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return sorted[middle - 1] / 2 + sorted[middle] / 2
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func coverage(_ scores: Scores) -> String {
        guard scores.scoredSeconds > 0 else { return "—" }
        return String(format: "%.1f%%", 100 * scores.answeredSeconds / scores.scoredSeconds)
    }

    private static func scoredTime(_ value: Double, _ scores: Scores) -> String {
        scores.scoredSeconds > 0 ? seconds(value) : "—"
    }

    private static func correctionCount(_ scores: Scores) -> String {
        let total = scores.corrections.count + scores.unresolved
        return total > 0 ? "\(scores.corrections.count) / \(total)" : "—"
    }
}
#endif
