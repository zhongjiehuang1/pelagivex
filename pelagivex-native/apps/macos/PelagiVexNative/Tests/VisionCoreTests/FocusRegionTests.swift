import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import VisionCore

@Suite struct FocusRegionTests {
    @Test func letterboxingAndMirroringRoundTrip() throws {
        let view = CGSize(width: 800, height: 800), source = CGSize(width: 1600, height: 900)
        #expect(FocusRegion.imageRect(view: view, image: source) == CGRect(x: 0, y: 175, width: 800, height: 450))
        for mirrored in [false, true] {
            let r = try #require(FocusRegion.selection(start: CGPoint(x: 80, y: 220), end: CGPoint(x: 320, y: 580), view: view, image: source, mirrored: mirrored))
            let display = r.displayRect(view: view, image: source, mirrored: mirrored)
            #expect(abs(display.minX - 80) < 0.001)
            #expect(abs(display.minY - 220) < 0.001)
            #expect(abs(display.width - 240) < 0.001)
            #expect(abs(r.x - (mirrored ? 0.6 : 0.1)) < 0.001)
        }
    }
    @Test func clipsEndButRejectsLetterboxAndTinySelection() throws {
        let v = CGSize(width: 800, height: 800), i = CGSize(width: 1600, height: 900)
        #expect(FocusRegion.selection(start: .zero, end: CGPoint(x: 500, y: 500), view: v, image: i, mirrored: false) == nil)
        #expect(FocusRegion.selection(start: CGPoint(x: 80, y: 220), end: CGPoint(x: 81, y: 222), view: v, image: i, mirrored: false) == nil)
        let r = try #require(FocusRegion.selection(start: CGPoint(x: 80, y: 220), end: CGPoint(x: 900, y: 900), view: v, image: i, mirrored: false))
        #expect(abs(r.x + r.width - 1) < 0.001)
        #expect(abs(r.y + r.height - 1) < 0.001)
    }
    @Test func invalidCoordinates() {
        #expect(FocusRegion(x: .nan, y: 0, width: 1, height: 1) == nil)
        #expect(FocusRegion(x: 0, y: 0, width: -1, height: 1) == nil)
        #expect(FocusRegion(x: 0.5, y: 0, width: 1, height: 1) == nil)
    }
}
