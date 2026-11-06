import XCTest
@testable import VisionCore

final class CoreTests: XCTestCase {
    func testLetterboxLandscape() {
        let g = Letterbox(width: 1920,height: 1080,size: 512)
        XCTAssertEqual(g.padX,0,accuracy: 0.0001); XCTAssertEqual(g.padY,112,accuracy: 0.0001)
        let b = g.source(Box(0,112,512,400))
        XCTAssertEqual(b.x2,1920,accuracy: 0.001); XCTAssertEqual(b.y2,1080,accuracy: 0.001)
    }
    func testLetterboxPortrait() {
        let g = Letterbox(width: 1080,height: 1920,size: 512)
        XCTAssertEqual(g.padX,112,accuracy: 0.0001); XCTAssertEqual(g.padY,0)
    }
    func testBoxIoU() { XCTAssertEqual(Box(0,0,2,2).iou(Box(1,1,3,3)),1.0/7,accuracy: 0.0001) }
    func testInvalidBox() { XCTAssertFalse(Box(.nan,0,1,1).valid); XCTAssertFalse(Box(1,0,0,1).valid) }
    private func tensor(_ rows: [[Float]]) -> [Float] {
        (0..<rows[0].count).flatMap { c in rows.map { $0[c] } }
    }
    func testSameClassNMS() throws {
        // cx,cy,w,h,class0,class1,mask0
        let a: [Float] = [20,20,10,10,0.9,0.1,1]
        let b: [Float] = [20,20,10,10,0.8,0.2,2]
        let out = try Decoder.decode(tensor([a,b]),classes: 2,channels: 1,anchors: 2)
        XCTAssertEqual(out.count,1); XCTAssertEqual(out[0].coefficients,[1])
        XCTAssertEqual(out[0].box,Box(15,15,25,25))
    }
    func testDifferentClassesPreserved() throws {
        let rows: [[Float]] = [[20,20,10,10,0.9,0.1,1],[20,20,10,10,0.1,0.8,2]]
        XCTAssertEqual(try Decoder.decode(tensor(rows),classes: 2,channels: 1,anchors: 2).count,2)
    }
    func testThresholdInclusive() throws {
        XCTAssertEqual(try Decoder.decode([5,5,2,2,0.35,1],classes: 1,channels: 1,anchors: 1).count,1)
    }
    func testRejectsBadShapeAndScores() throws {
        XCTAssertThrowsError(try Decoder.decode([],classes: 1,channels: 1,anchors: 1))
        XCTAssertEqual(try Decoder.decode([5,5,2,2,.nan,1],classes: 1,channels: 1,anchors: 1).count,0)
        XCTAssertEqual(try Decoder.decode([5,5,2,2,1.2,1],classes: 1,channels: 1,anchors: 1).count,0)
        XCTAssertEqual(try Decoder.decode([5,5,2,2,0.9,.infinity],classes: 1,channels: 1,anchors: 1).count,0)
    }
    func testLimit() throws {
        let rows = (0..<50).map { [Float($0*20),Float(10),Float(5),Float(5),Float(0.9),Float(1)] }
        XCTAssertEqual(try Decoder.decode(tensor(rows),classes: 1,channels: 1,anchors: 50).count,25)
    }
    func testLatestSlotReplacesWaitingFrames() {
        let slot = LatestSlot<Int>()
        XCTAssertTrue(slot.offer(1)); XCTAssertFalse(slot.offer(2)); XCTAssertFalse(slot.offer(3))
        XCTAssertEqual(slot.take(),3); XCTAssertNil(slot.take()); XCTAssertTrue(slot.offer(4))
        slot.clear(); XCTAssertNil(slot.take()); XCTAssertTrue(slot.offer(5))
    }
    func testSnapshotClears() {
        let value = Snapshot<Int>(); XCTAssertNil(value.get()); value.set(2); XCTAssertEqual(value.get(),2)
        value.set(nil); XCTAssertNil(value.get())
    }
    func testTrackingAndExpiry() {
        let t = Tracker(); let d = Detection(classID: 0,score: 0.8,box: Box(0,0,20,20),coefficients: [1])
        let first = t.update([d],time: 1)[0].trackID
        XCTAssertEqual(t.update([d],time: 1.1)[0].trackID,first)
        XCTAssertNotEqual(t.update([d],time: 2)[0].trackID,first)
    }
    func testTrackingClassAndOneToOne() {
        let t = Tracker(); let a = Detection(classID: 0,score: 0.8,box: Box(0,0,20,20),coefficients: [1])
        let initial = t.update([a],time: 1)[0].trackID
        let two = t.update([a,a],time: 1.1)
        XCTAssertEqual(two[0].trackID,initial); XCTAssertNotEqual(two[0].trackID,two[1].trackID)
        let b = Detection(classID: 1,score: 0.8,box: a.box,coefficients: [1])
        XCTAssertNotEqual(t.update([b],time: 1.2)[0].trackID,initial)
    }
    func testMeterCountsUniqueFramesNotRefreshes() {
        let m = FrameMeter()
        m.add(sequence: 1,finished: 1,received: 0.99)
        m.add(sequence: 1,finished: 1.01,received: 0.99)
        m.add(sequence: 2,finished: 1.04,received: 1.02)
        XCTAssertEqual(m.read().fps,25,accuracy: 0.0001)
        XCTAssertEqual(m.read().p95MS,20,accuracy: 0.0001); XCTAssertEqual(m.read().count,2)
        m.reset(); XCTAssertEqual(m.read().count,0)
    }
    func testMeterBounded() {
        let m = FrameMeter()
        for i in 0..<500 { m.add(sequence: UInt64(i),finished: Double(i),received: Double(i)) }
        XCTAssertEqual(m.read().count,120)
    }
    func testContractRejectsUnsupportedModel() throws {
        let json = """
        {"schema":1,"format":"yolo-v8-11-seg","inputName":"image","inputSize":512,"predictionName":"p","prototypeName":"m","classNames":["person"],"maskChannels":32,"prototypeWidth":128,"prototypeHeight":128,"predictionCount":5376}
        """
        let good = try JSONDecoder().decode(ModelContract.self,from: Data(json.utf8)); XCTAssertNoThrow(try good.validate())
        let bad = try JSONDecoder().decode(ModelContract.self,from: Data(json.replacingOccurrences(of: "yolo-v8-11-seg",with: "gate").utf8))
        XCTAssertThrowsError(try bad.validate())
    }
}
