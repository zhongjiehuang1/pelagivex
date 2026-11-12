import Testing
import Foundation
@testable import VisionCore

struct CoreTests {
    @Test func testLetterboxLandscape() {
        let g = Letterbox(width: 1920,height: 1080,size: 512)
        #expect(abs(g.padX - 0) <= 0.0001); #expect(abs(g.padY - 112) <= 0.0001)
        let b = g.source(Box(0,112,512,400))
        #expect(abs(b.x2 - 1920) <= 0.001); #expect(abs(b.y2 - 1080) <= 0.001)
    }
    @Test func testLetterboxPortrait() {
        let g = Letterbox(width: 1080,height: 1920,size: 512)
        #expect(abs(g.padX - 112) <= 0.0001); #expect(g.padY == 0)
    }
    @Test func testBoxIoU() { #expect(abs(Box(0,0,2,2).iou(Box(1,1,3,3)) - 1.0/7) <= 0.0001) }
    @Test func testInvalidBox() { #expect(!(Box(.nan,0,1,1).valid)); #expect(!(Box(1,0,0,1).valid)) }
    private func tensor(_ rows: [[Float]]) -> [Float] {
        (0..<rows[0].count).flatMap { c in rows.map { $0[c] } }
    }
    @Test func testSameClassNMS() throws {
        // cx,cy,w,h,class0,class1,mask0
        let a: [Float] = [20,20,10,10,0.9,0.1,1]
        let b: [Float] = [20,20,10,10,0.8,0.2,2]
        let out = try Decoder.decode(tensor([a,b]),classes: 2,channels: 1,anchors: 2)
        #expect(out.count == 1); #expect(out[0].coefficients == [1])
        #expect(out[0].box == Box(15,15,25,25))
    }
    @Test func testDifferentClassesPreserved() throws {
        let rows: [[Float]] = [[20,20,10,10,0.9,0.1,1],[20,20,10,10,0.1,0.8,2]]
        #expect(try Decoder.decode(tensor(rows),classes: 2,channels: 1,anchors: 2).count == 2)
    }
    @Test func testThresholdInclusive() throws {
        #expect(try Decoder.decode([5,5,2,2,0.35,1],classes: 1,channels: 1,anchors: 1).count == 1)
    }
    @Test func testRawAlternativeScoresAreSortedWithoutNormalization() throws {
        let result = try Decoder.decode([5, 5, 2, 2, 0.5, 0.6, 0.1, 1], classes: 3, channels: 1, anchors: 1)
        let item = try #require(result.first)
        #expect(item.classID == 1)
        #expect(item.score == 0.6)
        #expect(item.classConfidences.map(\.classID) == [1, 0, 2])
        #expect(item.classConfidences.map(\.score) == [0.6, 0.5, 0.1])
    }
    @Test func testExpandedSceneLimitCanRetainMoreThanTwentyFiveObjects() throws {
        let rows = (0..<60).map { [Float($0*20), Float(10), Float(5), Float(5), Float(0.3), Float(1)] }
        let result = try Decoder.decode(tensor(rows), classes: 1, channels: 1, anchors: 60,
                                        confidence: 0.1, limit: 100)
        #expect(result.count == 60)
    }
    @Test func testRejectsBadShapeAndScores() throws {
        #expect(throws: (any Error).self) { try Decoder.decode([],classes: 1,channels: 1,anchors: 1) }
        #expect(try Decoder.decode([5,5,2,2,.nan,1],classes: 1,channels: 1,anchors: 1).count == 0)
        #expect(try Decoder.decode([5,5,2,2,1.2,1],classes: 1,channels: 1,anchors: 1).count == 0)
        #expect(try Decoder.decode([5,5,2,2,0.9,.infinity],classes: 1,channels: 1,anchors: 1).count == 0)
    }
    @Test func testLimit() throws {
        let rows = (0..<50).map { [Float($0*20),Float(10),Float(5),Float(5),Float(0.9),Float(1)] }
        #expect(try Decoder.decode(tensor(rows),classes: 1,channels: 1,anchors: 50).count == 25)
    }
    @Test func testLatestSlotReplacesWaitingFrames() {
        let slot = LatestSlot<Int>()
        #expect(slot.offer(1)); #expect(!(slot.offer(2))); #expect(!(slot.offer(3)))
        #expect(slot.take() == 3); #expect(slot.take() == nil); #expect(slot.offer(4))
        slot.clear(); #expect(slot.take() == nil); #expect(slot.offer(5))
    }
    @Test func testSnapshotClears() {
        let value = Snapshot<Int>(); #expect(value.get() == nil); value.set(2); #expect(value.get() == 2)
        value.set(nil); #expect(value.get() == nil)
    }
    @Test func testTrackingAndExpiry() {
        let t = Tracker(); let d = Detection(classID: 0,score: 0.8,box: Box(0,0,20,20),coefficients: [1])
        let first = t.update([d],time: 1)[0].trackID
        #expect(t.update([d],time: 1.1)[0].trackID == first)
        #expect(t.update([d],time: 2)[0].trackID != first)
    }
    @Test func testTrackingClassAndOneToOne() {
        let t = Tracker(); let a = Detection(classID: 0,score: 0.8,box: Box(0,0,20,20),coefficients: [1])
        let initial = t.update([a],time: 1)[0].trackID
        let two = t.update([a,a],time: 1.1)
        #expect(two[0].trackID == initial); #expect(two[0].trackID != two[1].trackID)
        let b = Detection(classID: 1,score: 0.8,box: a.box,coefficients: [1])
        #expect(t.update([b],time: 1.2)[0].trackID != initial)
    }
    @Test func testMeterCountsUniqueFramesNotRefreshes() {
        let m = FrameMeter()
        m.add(sequence: 1,finished: 1,received: 0.99)
        m.add(sequence: 1,finished: 1.01,received: 0.99)
        m.add(sequence: 2,finished: 1.04,received: 1.02)
        #expect(abs(m.read().fps - 25) <= 0.0001)
        #expect(abs(m.read().p95MS - 20) <= 0.0001); #expect(m.read().count == 2)
        m.reset(); #expect(m.read().count == 0)
    }
    @Test func testMeterBounded() {
        let m = FrameMeter()
        for i in 0..<500 { m.add(sequence: UInt64(i),finished: Double(i),received: Double(i)) }
        #expect(m.read().count == 120)
    }
    @Test func testContractRejectsUnsupportedModel() throws {
        let json = """
        {"schema":1,"format":"yolo-v8-11-seg","inputName":"image","inputSize":512,"predictionName":"p","prototypeName":"m","classNames":["person"],"maskChannels":32,"prototypeWidth":128,"prototypeHeight":128,"predictionCount":5376}
        """
        let good = try JSONDecoder().decode(ModelContract.self,from: Data(json.utf8)); try good.validate()
        let bad = try JSONDecoder().decode(ModelContract.self,from: Data(json.replacingOccurrences(of: "yolo-v8-11-seg",with: "gate").utf8))
        #expect(throws: (any Error).self) { try bad.validate() }
    }
}
