import Testing
@testable import VisionCore

struct AutoOrbitPolicyTests {
    @Test func advancesOnlyAfterEnoughTimeAndCommittedSamples() {
        var policy = AutoOrbitPolicy()
        policy.start(at: 10)

        let initial = policy.update(acceptedPhotos: 0, acceptedByStage: [:], at: 16)
        #expect(initial == .needsMoreViews)
        #expect(policy.stage == .front)

        let advance = policy.update(acceptedPhotos: 6, acceptedByStage: [.front: 6], at: 17)
        #expect(advance == .keepCapturing)
        #expect(policy.stage == .firstSide)

        _ = policy.update(acceptedPhotos: 12, acceptedByStage: [.front: 6, .firstSide: 6], at: 20)
        #expect(policy.stage == .firstSide)
        _ = policy.update(acceptedPhotos: 12, acceptedByStage: [.front: 6, .firstSide: 6], at: 23)
        #expect(policy.stage == .back)
    }

    @Test func pauseDoesNotAdvanceGuidanceOrSpendActiveTime() {
        var policy = AutoOrbitPolicy()
        policy.start(at: 10)
        policy.pause(at: 14)

        _ = policy.update(acceptedPhotos: 6, acceptedByStage: [.front: 6], at: 50)
        #expect(policy.stage == .front)
        #expect(policy.elapsed(at: 50) == 4)

        policy.resume(at: 50)
        _ = policy.update(acceptedPhotos: 6, acceptedByStage: [.front: 6], at: 51)
        #expect(policy.stage == .front)
        _ = policy.update(acceptedPhotos: 6, acceptedByStage: [.front: 6], at: 52)
        #expect(policy.stage == .firstSide)
    }

    @Test func automaticReconstructionRequiresSamplesFromEveryStageAndActiveDuration() {
        var policy = AutoOrbitPolicy()
        policy.start(at: 0)
        var counts: [AutoOrbitPolicy.Stage: Int] = [:]
        for stage in AutoOrbitPolicy.Stage.allCases.dropLast() {
            counts[stage] = 6
            let decision = policy.update(acceptedPhotos: counts.count * 6, acceptedByStage: counts,
                                         at: Double(counts.count) * 6)
            #expect(decision == .keepCapturing)
        }
        #expect(policy.stage == .upper)

        counts[.upper] = 6
        let early = policy.update(acceptedPhotos: 30, acceptedByStage: counts, at: 30)
        #expect(early == .keepCapturing)

        var incomplete = counts
        incomplete[.back] = 5
        incomplete[.upper] = 7
        let moreNeeded = policy.update(acceptedPhotos: 30, acceptedByStage: incomplete, at: 36)
        #expect(moreNeeded != .reconstruct)

        let ready = policy.update(acceptedPhotos: 30, acceptedByStage: counts, at: 36)
        #expect(ready == .reconstruct)
    }
}
