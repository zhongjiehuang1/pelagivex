import Testing
@testable import VisionCore

struct ContourPropagationTests {
    private func detection(_ id: Int = 7, classID: Int = 2, box: Box = Box(128, 128, 384, 384)) -> Detection {
        var detection = Detection(classID: classID, score: 0.9, box: box, coefficients: [])
        detection.trackID = id
        return detection
    }
    private func warps(_ source: [Detection], _ current: [Detection], received: Double = 10.2,
                       now: Double = 10.3) -> [ContourWarp] {
        ContourPropagation.warps(source: source, current: current,
            sourceWidth: 640, sourceHeight: 640, currentWidth: 640, currentHeight: 640,
            inputSize: 640, sourceReceived: 10, currentReceived: received, now: now)
    }

    @Test func recentSameTrackContourFollowsModerateMotion() throws {
        let matches = warps([detection()], [detection(box: Box(144, 144, 400, 400))])
        let warp = try #require(matches.first)
        let point = try #require(warp.sourcePoint(for: SIMD2(0.425, 0.425)))
        #expect(abs(point.x-0.4) < 0.00001 && abs(point.y-0.4) < 0.00001)
        #expect(warp.sourcePoint(for: SIMD2(0.21, 0.3)) == nil)
        #expect(warp.sourcePoint(for: SIMD2(0.625, 0.3)) == nil)
    }

    @Test func expiredFutureAndFrozenEvidenceAreRejected() {
        let source = [detection()], current = [detection()]
        #expect(warps(source, current, received: 10.651, now: 10.651).isEmpty)
        #expect(warps(source, current, received: 9.99, now: 10.1).isEmpty)
        #expect(warps(source, current, received: 10.1, now: 10.651).isEmpty)
        #expect(warps(source, current, received: 10.1, now: .nan).isEmpty)
        #expect(warps(source, current, received: 10.64, now: 10.64).count == 1)
    }

    @Test func changedClassMissingOrAmbiguousTrackCannotInheritContours() {
        #expect(warps([detection()], [detection(classID: 3)]).isEmpty)
        #expect(warps([detection()], [detection(8)]).isEmpty)
        #expect(warps([detection(0)], [detection(0)]).isEmpty)
        #expect(warps([detection(), detection()], [detection()]).isEmpty)
        #expect(warps([detection()], [detection(), detection()]).isEmpty)
        #expect(warps([detection()], []).isEmpty)
    }

    @Test func abruptMotionAndScaleChangesFallBackToCurrentMasks() {
        #expect(warps([detection()], [detection(box: Box(300, 128, 556, 384))]).isEmpty)
        // Both boxes still overlap strongly; independent scale gates reject these changes.
        #expect(warps([detection()], [detection(box: Box(128, 128, 492, 384))]).isEmpty)
        #expect(warps([detection()], [detection(box: Box(128, 128, 384, 300))]).isEmpty)
        #expect(warps([detection()], [detection(box: Box(.nan, 128, 384, 384))]).isEmpty)
    }

    @Test func sourceIDsRemapWhenDetectionOrderChangesAndObjectsDisappear() {
        let source = [detection(11), detection(22), detection(33)]
        let current = [detection(33), detection(44), detection(11)]
        let matches = warps(source, current)
        #expect(matches.map(\.currentIndex) == [0, 2])
        #expect(matches.map(\.sourceIndex) == [2, 0])
        // The disappeared ID 22 and new ID 44 have no reusable mask; raw old IDs are never colors.
        #expect(!matches.contains { $0.sourceIndex == 1 || $0.currentIndex == 1 })
    }

    @Test func letterboxIsRemovedBeforeNormalizedSourceWarp() throws {
        // A 1920x1080 frame has 140px vertical padding in the 640px model input.
        let fullImage = detection(box: Box(0, 140, 640, 500))
        let normalized = try #require(ContourPropagation.normalizedSourceBox(fullImage,
            width: 1920, height: 1080, inputSize: 640))
        #expect(abs(normalized.x1) < 0.00001 && abs(normalized.y1) < 0.00001)
        #expect(abs(normalized.x2-1) < 0.00001 && abs(normalized.y2-1) < 0.00001)
        let matches = ContourPropagation.warps(source: [fullImage], current: [fullImage],
            sourceWidth: 1920, sourceHeight: 1080, currentWidth: 1280, currentHeight: 720,
            inputSize: 640, sourceReceived: 10, currentReceived: 10.2, now: 10.3)
        #expect(matches.count == 1)
        #expect(ContourPropagation.warps(source: [fullImage], current: [fullImage],
            sourceWidth: 1920, sourceHeight: 1080, currentWidth: 1080, currentHeight: 1920,
            inputSize: 640, sourceReceived: 10, currentReceived: 10.2, now: 10.3).isEmpty)
    }
}
