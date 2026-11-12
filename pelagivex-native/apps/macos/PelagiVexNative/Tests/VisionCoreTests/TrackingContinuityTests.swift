import Foundation
import Testing
@testable import VisionCore

struct TrackingContinuityTests {
    private func detection(_ x: Float = 100, score: Float = 0.9, classID: Int = 0,
                           width: Float = 20, coefficients: [Float] = [1],
                           alternatives: [ClassConfidence] = []) -> Detection {
        Detection(classID: classID, score: score, box: Box(x, 100, x + width, 120),
                  coefficients: coefficients, classConfidences: alternatives)
    }

    @Test func briefMissRetainsIdentityWithoutReturningAnOldMask() throws {
        let tracker = Tracker()
        let observed = try #require(tracker.update([detection()], time: 1).first)
        #expect(tracker.update([], time: 1.05).isEmpty)
        #expect(tracker.update([], time: 1.20).isEmpty)
        let waiting = try #require(tracker.snapshots.first)
        #expect(waiting.id == observed.trackID)
        #expect(waiting.lastSeen == 1)
        #expect(!waiting.isObserved)
        #expect(waiting.detection.box == observed.box)

        let recovered = try #require(tracker.update([detection(102, coefficients: [2])], time: 1.30).first)
        #expect(recovered.trackID == observed.trackID)
        #expect(recovered.coefficients == [2])
        let current = try #require(tracker.snapshots.first)
        #expect(current.isObserved)
        #expect(current.lastSeen == 1.30)
        #expect(current.detection.coefficients == [2])
    }

    @Test func expiredTrackCannotBeRecoveredByTheSameClassAndBox() throws {
        let tracker = Tracker()
        let original = try #require(tracker.update([detection()], time: 1).first)
        #expect(tracker.update([], time: 1.4).isEmpty)
        #expect(tracker.update([], time: 1.81).isEmpty)
        #expect(tracker.snapshots.isEmpty)
        let replacement = try #require(tracker.update([detection()], time: 1.82).first)
        #expect(replacement.trackID != original.trackID)
    }

    @Test func focusedTrackHasLongerRecoveryWithoutReturningAnOldMask() throws {
        let tracker = Tracker()
        let first = tracker.update([detection(), detection(180)], time: 1)
        let focus = try #require(first.first?.trackID)
        #expect(tracker.update([], time: 2.0, focusedTrackID: focus).isEmpty)
        #expect(tracker.snapshots.map(\.id) == [focus])
        #expect(tracker.snapshots.first?.isObserved == false)

        let recovered = try #require(tracker.update([detection(102, coefficients: [2])], time: 2.1, focusedTrackID: focus).first)
        #expect(recovered.trackID == focus)
        #expect(recovered.coefficients == [2])
    }

    @Test func lateFocusedTrackDoesNotTakeASeparateNearbyDetection() throws {
        let tracker = Tracker()
        let focus = try #require(tracker.update([detection()], time: 1).first?.trackID)
        let nearby = try #require(tracker.update([detection(115)], time: 2.0, focusedTrackID: focus).first)
        #expect(nearby.trackID != focus)
        #expect(tracker.snapshots.first(where: { $0.id == focus })?.isObserved == false)
    }

    @Test func velocityPredictionBridgesABriefMovingTargetGap() throws {
        let tracker = Tracker()
        let original = try #require(tracker.update([detection(100)], time: 1).first)
        let second = try #require(tracker.update([detection(108)], time: 1.05).first)
        let third = try #require(tracker.update([detection(116)], time: 1.10).first)
        #expect(second.trackID == original.trackID)
        #expect(third.trackID == original.trackID)
        #expect(tracker.update([], time: 1.15).isEmpty)
        // At 160 pixels/s, 0.15 s after the last observation, the boxes no longer overlap.
        let reappeared = detection(140)
        #expect(third.box.iou(reappeared.box) == 0)
        let recovered = try #require(tracker.update([reappeared], time: 1.25).first)
        #expect(recovered.trackID == original.trackID)
    }

    @Test func reorderedSameClassDetectionsKeepDistinctIdentities() throws {
        let tracker = Tracker()
        let first = tracker.update([detection(100, score: 0.95), detection(160, score: 0.8)], time: 1)
        try #require(first.count == 2)
        let next = tracker.update([detection(158, score: 0.96), detection(102, score: 0.7)], time: 1.05)
        try #require(next.count == 2)
        #expect(next[0].trackID == first[1].trackID)
        #expect(next[1].trackID == first[0].trackID)
        #expect(Set(next.map(\.trackID)).count == next.count)
    }

    @Test func distantNewcomerCannotStealARetainedIdentity() throws {
        let tracker = Tracker()
        let original = try #require(tracker.update([detection(100)], time: 1).first)
        #expect(tracker.update([], time: 1.1).isEmpty)
        let newcomer = try #require(tracker.update([detection(500)], time: 1.2).first)
        #expect(newcomer.trackID != original.trackID)
        #expect(tracker.snapshots.contains { $0.id == original.trackID && !$0.isObserved })
        let both = tracker.update([detection(102), detection(501)], time: 1.25)
        try #require(both.count == 2)
        #expect(both[0].trackID == original.trackID)
        #expect(both[1].trackID == newcomer.trackID)
    }


    @Test func weakObservationContinuesButDoesNotCreateATrack() throws {
        let tracker = Tracker()
        #expect(tracker.update([detection(score: 0.14)], time: 1, newTrackThreshold: 0.3).isEmpty)
        #expect(tracker.snapshots.isEmpty)
        let strong = try #require(tracker.update([detection()], time: 1.05, newTrackThreshold: 0.3).first)
        let weak = try #require(tracker.update([detection(101, score: 0.14)], time: 1.10,
                                              newTrackThreshold: 0.3).first)
        #expect(weak.trackID == strong.trackID)
        #expect(weak.score == 0.14)
        #expect(tracker.snapshots.count == 1)
    }

    @Test func strongObservationHasPriorityOverAWeakCompetingBox() throws {
        let tracker = Tracker()
        let original = try #require(tracker.update([detection(width: 40)], time: 1,
                                                  newTrackThreshold: 0.3).first)
        let next = tracker.update([detection(101, score: 0.14, width: 40),
                                   detection(105, score: 0.9, width: 40)], time: 1.05,
                                  newTrackThreshold: 0.3)
        #expect(next.count == 1)
        #expect(next.first?.trackID == original.trackID)
        #expect(next.first?.score == 0.9)
    }

    @Test func unsupportedClassChangeDoesNotReuseAnIdentity() throws {
        let tracker = Tracker()
        let original = try #require(tracker.update([detection(classID: 0)], time: 1).first)
        let changed = try #require(tracker.update([detection(classID: 1)], time: 1.05).first)
        #expect(changed.trackID != original.trackID)
    }

    @Test func mutuallySupportedClassAlternativesAllowLabelFlicker() throws {
        let tracker = Tracker()
        let original = try #require(tracker.update([
            detection(score: 0.55, classID: 0,
                      alternatives: [ClassConfidence(classID: 0, score: 0.55),
                                     ClassConfidence(classID: 1, score: 0.50)])
        ], time: 1).first)
        let changed = try #require(tracker.update([
            detection(101, score: 0.56, classID: 1,
                      alternatives: [ClassConfidence(classID: 1, score: 0.56),
                                     ClassConfidence(classID: 0, score: 0.51)])
        ], time: 1.05).first)
        #expect(changed.trackID == original.trackID)
    }

    @Test func rawClassAlternativeScoresArePreserved() throws {
        let tracker = Tracker()
        let original = detection(score: 0.55,
                                 alternatives: [ClassConfidence(classID: 0, score: 0.55),
                                                ClassConfidence(classID: 1, score: 0.45)])
        let tracked = try #require(tracker.update([original], time: 1).first)
        #expect(tracked.score == original.score)
        #expect(tracked.classConfidences.count == 2)
        #expect(tracked.classConfidences.map(\.classID) == [0, 1])
        #expect(tracked.classConfidences.map(\.score) == [0.55, 0.45])
        let snapshot = try #require(tracker.snapshots.first)
        #expect(snapshot.detection.classConfidences.map(\.score) == [0.55, 0.45])
    }

    @Test func invalidClockClearsTracksAndDoesNotEmitCurrentDetections() throws {
        for time in [Double.nan, Double.infinity, -1] {
            let tracker = Tracker()
            let previous = try #require(tracker.update([detection()], time: 1).first)
            #expect(tracker.update([detection()], time: time).isEmpty)
            #expect(tracker.snapshots.isEmpty)
            let current = try #require(tracker.update([detection()], time: 1.1).first)
            #expect(current.trackID != previous.trackID)
        }
    }

    @Test func backwardsClockStartsANewIdentityAndResetRemovesSnapshots() throws {
        let tracker = Tracker()
        let previous = try #require(tracker.update([detection()], time: 5).first)
        let current = try #require(tracker.update([detection()], time: 4).first)
        #expect(current.trackID != previous.trackID)
        tracker.reset()
        #expect(tracker.snapshots.isEmpty)
    }
}
