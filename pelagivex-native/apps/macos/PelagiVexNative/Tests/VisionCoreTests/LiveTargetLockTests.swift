import Testing
@testable import VisionCore

struct LiveTargetLockTests {
    @Test func requiresFreshDistinctObservationsAndKeepsIdentityWhenAnotherTargetScoresHigher() {
        var lock = LiveTargetLock()
        let first = LiveTargetLock.Candidate(id: 7, priority: 0.6)
        let competitor = LiveTargetLock.Candidate(id: 8, priority: 0.95)
        #expect(lock.update([first], sequence: 1, frameTime: 10, now: 10) == nil)
        #expect(lock.update([first], sequence: 1, frameTime: 10, now: 10.05) == nil)
        #expect(lock.update([first], sequence: 2, frameTime: 10.08, now: 10.08) == nil)
        #expect(lock.update([first], sequence: 3, frameTime: 10.16, now: 10.16) == 7)
        for i in 4...10 {
            let time = 10.5 + Double(i - 3) * 0.1
            #expect(lock.update([competitor, .init(id: 7, priority: nil)], sequence: UInt64(i),
                                frameTime: time, now: time) == 7)
        }
    }

    @Test func hidesStaleTargetAndWaitsBeforeReplacingItsIdentity() {
        var lock = LiveTargetLock()
        let a = LiveTargetLock.Candidate(id: 1, priority: 0.6)
        let b = LiveTargetLock.Candidate(id: 2, priority: 0.9)
        for i in 0...2 {
            let time = 10 + Double(i) * 0.25
            _ = lock.update([a], sequence: UInt64(i), frameTime: time, now: time)
        }
        #expect(lock.update([a], sequence: 2, frameTime: 10.5, now: 11) == nil)
        #expect(lock.reservedID == 1)
        #expect(lock.update([a], sequence: 3, frameTime: 11.1, now: 11.1) == 1)
        #expect(lock.update([b], sequence: 4, frameTime: 11.25, now: 11.25) == nil)
        #expect(lock.reservedID == 1)
        #expect(lock.update([b], sequence: 5, frameTime: 11.5, now: 11.5) == nil)
        #expect(lock.update([b], sequence: 6, frameTime: 11.75, now: 11.75) == nil)
        #expect(lock.update([b], sequence: 7, frameTime: 12, now: 12) == nil)
        #expect(lock.update([b], sequence: 8, frameTime: 12.25, now: 12.25) == nil)
        #expect(lock.update([b], sequence: 9, frameTime: 12.50, now: 12.50) == nil)
        #expect(lock.update([b], sequence: 10, frameTime: 12.75, now: 12.75) == 2)
    }
}
