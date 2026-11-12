import Testing
import Foundation
@testable import VisionCore

struct PairPolicyTests {
    // Evaluate mutations directly; the expectation macro captures its receiver as immutable.
    private func check(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, sourceLocation: sourceLocation)
    }

    private let pair = PairSelection(22, 8)!
    private let boxA = Box(0.1, 0.1, 0.3, 0.3)
    private let boxB = Box(0.5, 0.1, 0.7, 0.3)
    private let movedA = Box(0.05, 0.05, 0.4, 0.4)

    private func geometry(at time: Double, selection: PairSelection? = nil, moved: Bool = false) -> PairGeometry {
        PairGeometry(selection: selection ?? pair, received: time, boxA: moved ? movedA : boxA, boxB: boxB)
    }

    @Test func testSelectionOrderAndNearTies() throws {
        #expect(pair.a == 22)
        #expect(pair.b == 8)
        #expect(PairSelection(8, 8) == nil)
        let encoded = try JSONEncoder().encode(pair)
        #expect(try JSONDecoder().decode(PairSelection.self, from: encoded) == pair)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PairSelection.self, from: Data(#"{"a":8,"b":8}"#.utf8)) }

        var policy = PairPolicy()
        let request = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        func order(_ a: Double, _ b: Double) -> PairOrdering? {
            PairMeasurement(request: request, depthA: a, depthB: b).ordering
        }
        #expect(order(1, 1.05) == .tooClose)
        #expect(order(3, 3.14) == .tooClose)
        #expect(order(3, 3.20) == .aCloser)
        #expect(order(3.20, 3) == .bCloser)
        #expect(order(.nan, 1) == nil)
        #expect(order(1, 0) == nil)
    }

    @Test func testConfirmationWaitsThroughAChangeButCanBeatTheNextPeriodicCall() throws {
        var adaptive = PairPolicy(mode: .adaptive)
        var baseline = PairPolicy(mode: .baseline)
        var adaptiveSubmissions = 0
        var baselineSubmissions = 0
        for step in 0..<10 {
            let time = Double(step) / 4
            let frame = geometry(at: time)
            if let request = adaptive.update(selection: pair, geometry: frame, now: time).request {
                check(adaptive.markSubmitted(request))
                check(adaptive.complete(PairMeasurement(request: request, depthA: 1, depthB: 2)))
                adaptiveSubmissions += 1
            }
            if let request = baseline.update(selection: pair, geometry: frame, now: time).request {
                check(baseline.markSubmitted(request))
                check(baseline.complete(PairMeasurement(request: request, depthA: 1, depthB: 2)))
                baselineSubmissions += 1
            }
        }
        let shifted = geometry(at: 2.5, moved: true)
        let adaptiveDecision = adaptive.update(selection: pair, geometry: shifted, now: 2.5)
        let baselineDecision = baseline.update(selection: pair, geometry: shifted, now: 2.5)
        #expect(adaptiveDecision.ordering == nil)
        #expect(adaptiveDecision.risk == .changed)
        #expect(adaptiveDecision.request == nil)
        #expect(baselineDecision.ordering == .aCloser)
        #expect(baselineDecision.request == nil)
        #expect(adaptive.update(selection: pair, geometry: geometry(at: 3, moved: true), now: 3).request == nil)
        for time in [3.25, 3.5] {
            #expect(adaptive.update(selection: pair, geometry: geometry(at: time, moved: true), now: time).request == nil)
        }
        let postChange = geometry(at: 3.75, moved: true)
        let request = try #require(adaptive.update(selection: pair, geometry: postChange, now: 3.75).request)
        check(adaptive.markSubmitted(request))
        check(adaptive.complete(PairMeasurement(request: request, depthA: 2, depthB: 1)))
        adaptiveSubmissions += 1
        #expect(adaptiveSubmissions == baselineSubmissions)
        #expect(adaptive.update(selection: pair, geometry: postChange, now: 3.75).ordering == .bCloser)
    }

    @Test func testLateralTranslationAloneDoesNotWithdrawARecentAnswer() throws {
        var policy = PairPolicy()
        let request = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        check(policy.markSubmitted(request))
        check(policy.complete(PairMeasurement(request: request, depthA: 1, depthB: 2)))
        let translated = PairGeometry(selection: pair, received: 0.25, boxA: Box(0.22, 0.1, 0.42, 0.3), boxB: boxB)
        let decision = policy.update(selection: pair, geometry: translated, now: 0.25)
        #expect(decision.ordering == .aCloser)
        #expect(decision.request == nil)
    }
    @Test func testRejectedAndStaleProposalsDoNotSpendBudget() throws {
        var policy = PairPolicy()
        let old = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        let current = try #require(policy.update(selection: pair, geometry: geometry(at: 0.25), now: 0.25).request)
        check(!(policy.markSubmitted(old)))
        check(policy.markSubmitted(current))
        check(!(policy.markSubmitted(current)))
        check(policy.fail(current))
        #expect(policy.update(selection: pair, geometry: geometry(at: 0.75), now: 0.75).request == nil)
    }

    @Test func testLateCompletionCannotValidateAReselectedPair() throws {
        var policy = PairPolicy()
        let first = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        check(policy.markSubmitted(first))
        let other = try #require(PairSelection(pair.a, 17))
        _ = policy.update(selection: other, geometry: geometry(at: 0.25, selection: other), now: 0.25)
        #expect(policy.update(selection: pair, geometry: geometry(at: 0.5), now: 0.5).ordering == nil)
        check(!(policy.complete(PairMeasurement(request: first, depthA: 1, depthB: 2))))
        let next = try #require(policy.update(selection: pair, geometry: geometry(at: 2), now: 2).request)
        check(policy.markSubmitted(next))
        check(!(policy.fail(first)))
        check(policy.complete(PairMeasurement(request: next, depthA: 2, depthB: 1)))
        #expect(policy.update(selection: pair, geometry: geometry(at: 2), now: 2).ordering == .bCloser)
    }

    @Test func testAdaptiveDropsCompletionAfterObservedMotionOrGap() throws {
        var policy = PairPolicy()
        let first = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        check(policy.markSubmitted(first))
        #expect(policy.update(selection: pair, geometry: geometry(at: 0.25, moved: true), now: 0.25).risk == .changed)
        #expect(policy.update(selection: pair, geometry: geometry(at: 0.5), now: 0.5).ordering == nil)
        check(!(policy.complete(PairMeasurement(request: first, depthA: 1, depthB: 2))))
        let second = try #require(policy.update(selection: pair, geometry: geometry(at: 2), now: 2).request)
        #expect(second.reason == .gap)
        check(policy.markSubmitted(second))
        #expect(policy.update(selection: pair, geometry: nil, now: 2.25).risk == .gap)
        check(!(policy.complete(PairMeasurement(request: second, depthA: 1, depthB: 2))))
    }

    @Test func testAdaptiveBudgetAndCooldownOverSustainedChange() throws {
        var policy = PairPolicy()
        var submitted = [Double]()
        for step in 0...120 {
            let time = Double(step) / 4
            let frame = geometry(at: time, moved: step % 2 != 0)
            let decision = policy.update(selection: pair, geometry: frame, now: time)
            if let request = decision.request {
                if let previous = submitted.last { #expect(time - previous >= 0.5) }
                check(policy.markSubmitted(request))
                check(policy.complete(PairMeasurement(request: request, depthA: 1, depthB: 2)))
                submitted.append(time)
                #expect(Double(submitted.count) <= 1 + time / 2)
            }
        }
        #expect(submitted.count > 2)
    }

    @Test func testMeasurementAgeUsesSourceFrameTimeInBothModes() throws {
        for (mode, maxAge) in [(PairMode.adaptive, 3.0), (.baseline, 5.0)] {
            var policy = PairPolicy(mode: mode)
            let request = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0.25).request)
            check(policy.markSubmitted(request))
            check(policy.complete(PairMeasurement(request: request, depthA: 1, depthB: 2)))
            for step in 1..<Int(maxAge * 4) {
                let time = Double(step) / 4
                #expect(policy.update(selection: pair, geometry: geometry(at: time), now: time).ordering == .aCloser)
            }
            let expired = policy.update(selection: pair, geometry: geometry(at: maxAge), now: maxAge)
            #expect(expired.ordering == nil)
            #expect(expired.risk == .expired)
        }
    }

    @Test func testPresentationCanUseLaggingFrameButNeverFutureEvidence() throws {
        var policy = PairPolicy(mode: .baseline)
        let first = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        check(policy.markSubmitted(first))
        check(policy.complete(PairMeasurement(request: first, depthA: 1, depthB: 2)))
        _ = policy.update(selection: pair, geometry: geometry(at: 0.25), now: 0.25)
        let lagging = policy.presentation(selection: pair, geometry: geometry(at: 0.125), now: 0.25)
        #expect(lagging.ordering == .aCloser)
        #expect(lagging.request == nil)

        let second = try #require(policy.update(selection: pair, geometry: geometry(at: 2), now: 2).request)
        check(policy.markSubmitted(second))
        check(policy.complete(PairMeasurement(request: second, depthA: 2, depthB: 1)))
        #expect(policy.presentation(selection: pair, geometry: geometry(at: 1.75), now: 2).ordering == nil)
        #expect(policy.presentation(selection: pair, geometry: geometry(at: 2), now: 2).ordering == .bCloser)
    }

    @Test func testImmediateReselectionInvalidatesEvidenceAndKeepsBudget() throws {
        var policy = PairPolicy()
        let request = try #require(policy.update(selection: pair, geometry: geometry(at: 0), now: 0).request)
        check(policy.markSubmitted(request))
        policy.setSelection(nil)
        policy.setSelection(pair)
        check(!(policy.complete(PairMeasurement(request: request, depthA: 1, depthB: 2))))
        let decision = policy.update(selection: pair, geometry: geometry(at: 0.25), now: 0.25)
        #expect(decision.risk == .initial)
        #expect(decision.request == nil)
    }
}
