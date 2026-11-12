import Testing
@testable import VisionCore

struct TemporalConfirmationTests {
    private func detection(_ classID: Int = 0, x: Float = 100, score: Float = 0.9,
                           mask: Float = 1) -> Detection {
        Detection(classID: classID, score: score, box: Box(x, 100, x + 40, 140), coefficients: [mask],
                  classConfidences: [ClassConfidence(classID: classID, score: score)])
    }

    @Test func oneFrameTargetDoesNotBecomeAPublishedDetectionOrSnapshot() {
        let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
        #expect(tracker.update([detection()], time: 1, newTrackThreshold: 0.3).isEmpty)
        #expect(tracker.snapshots.isEmpty)
        #expect(tracker.update([], time: 1.05, newTrackThreshold: 0.3).isEmpty)
        #expect(tracker.snapshots.isEmpty)
    }

    @Test func secondConsecutiveObservationPublishesOnlyTheCurrentMaskAndScore() throws {
        let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
        #expect(tracker.update([detection(mask: 1)], time: 1, newTrackThreshold: 0.3).isEmpty)
        let result = try #require(tracker.update([detection(x: 101, score: 0.75, mask: 2)], time: 1.05,
                                               newTrackThreshold: 0.3).first)
        #expect(result.box.x1 == 101)
        #expect(result.coefficients == [2])
        #expect(result.score == 0.75)
        #expect(tracker.snapshots.first?.lastSeen == 1.05)
        #expect(tracker.snapshots.first?.isObserved == true)
    }

    @Test func aMissOrWeakObservationCannotCompleteTentativeConfirmation() throws {
        for middle in [[], [detection(score: 0.14)]] {
            let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
            #expect(tracker.update([detection()], time: 1, newTrackThreshold: 0.3).isEmpty)
            #expect(tracker.update(middle, time: 1.05, newTrackThreshold: 0.3).isEmpty)
            #expect(tracker.update([detection()], time: 1.10, newTrackThreshold: 0.3).isEmpty)
            #expect(tracker.snapshots.isEmpty)
            #expect(tracker.update([detection()], time: 1.15, newTrackThreshold: 0.3).count == 1)
        }
    }

    @Test func winningLabelFlickerKeepsIdentityWithoutInventingOldClassConfidence() throws {
        let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
        _ = tracker.update([detection()], time: 1, newTrackThreshold: 0.3)
        let first = try #require(tracker.update([detection(mask: 2)], time: 1.05, newTrackThreshold: 0.3).first)
        #expect(tracker.update([detection(7, score: 0.8, mask: 3)], time: 1.10,
                               newTrackThreshold: 0.3).isEmpty)
        let retained = try #require(tracker.snapshots.first)
        #expect(retained.id == first.trackID)
        #expect(retained.lastSeen == 1.05)
        #expect(!retained.isObserved)
        #expect(retained.detection.classID == 0)
        #expect(retained.detection.coefficients == [2])
        let recovered = try #require(tracker.update([detection(mask: 4)], time: 1.15,
                                                   newTrackThreshold: 0.3).first)
        #expect(recovered.trackID == first.trackID)
        #expect(recovered.classID == 0)
        #expect(recovered.coefficients == [4])
    }

    @Test func persistentNewLabelIsAcceptedWithCurrentEvidenceAndSameIdentity() throws {
        let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
        _ = tracker.update([detection()], time: 1, newTrackThreshold: 0.3)
        let first = try #require(tracker.update([detection()], time: 1.05, newTrackThreshold: 0.3).first)
        #expect(tracker.update([detection(7, score: 0.8)], time: 1.10, newTrackThreshold: 0.3).isEmpty)
        let changed = try #require(tracker.update([detection(7, score: 0.7, mask: 4)], time: 1.15,
                                                 newTrackThreshold: 0.3).first)
        #expect(changed.trackID == first.trackID)
        #expect(changed.classID == 7)
        #expect(changed.score == 0.7)
        #expect(changed.classConfidences == [ClassConfidence(classID: 7, score: 0.7)])
        #expect(changed.coefficients == [4])
    }

    @Test func ambiguousOverlappingTargetsDoNotPermitGeometryOnlyIdentityRecovery() throws {
        let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
        _ = tracker.update([detection(), detection(1)], time: 1, newTrackThreshold: 0.3)
        let first = tracker.update([detection(), detection(1)], time: 1.05, newTrackThreshold: 0.3)
        try #require(first.count == 2)
        #expect(tracker.update([detection(7)], time: 1.10, newTrackThreshold: 0.3).isEmpty)
        let changed = try #require(tracker.update([detection(7)], time: 1.15, newTrackThreshold: 0.3).first)
        #expect(!first.map(\.trackID).contains(changed.trackID))
        #expect(tracker.snapshots.filter { !$0.isObserved }.count == 2)
    }

    @Test func geometryOnlyRecoveryCannotBridgeAnOldOrDistantTarget() throws {
        for (time, x) in [(1.30, Float(100)), (1.10, Float(200))] {
            let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
            _ = tracker.update([detection()], time: 1, newTrackThreshold: 0.3)
            let first = try #require(tracker.update([detection()], time: 1.05, newTrackThreshold: 0.3).first)
            #expect(tracker.update([detection(7, x: x)], time: time, newTrackThreshold: 0.3).isEmpty)
            let replacement = try #require(tracker.update([detection(7, x: x)], time: time + 0.05,
                                                         newTrackThreshold: 0.3).first)
            #expect(replacement.trackID != first.trackID)
        }
    }

    @Test func confirmedTargetRetainsIdentityThroughMissingObservationsButReturnsNoOldMasks() throws {
        let tracker = Tracker(confirmationHits: 2, allowClassAgnosticRecovery: true)
        _ = tracker.update([detection()], time: 1, newTrackThreshold: 0.3)
        let first = try #require(tracker.update([detection()], time: 1.05, newTrackThreshold: 0.3).first)
        #expect(tracker.update([], time: 1.10, newTrackThreshold: 0.3).isEmpty)
        #expect(tracker.update([], time: 1.20, newTrackThreshold: 0.3).isEmpty)
        let recovered = try #require(tracker.update([detection(mask: 8)], time: 1.30,
                                                   newTrackThreshold: 0.3).first)
        #expect(recovered.trackID == first.trackID)
        #expect(recovered.coefficients == [8])
    }
}
