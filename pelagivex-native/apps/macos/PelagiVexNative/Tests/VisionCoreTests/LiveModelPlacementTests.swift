import Foundation
import PelagiVexCpp
import Testing

struct LiveModelPlacementTests {
    private let image = PVLiveRect(x: 0, y: 0, width: 1200, height: 800)
    private let fixedSize = CGSize(width: 260, height: 208)

    private func target(_ x: Double, _ y: Double) -> PVLiveRect {
        PVLiveRect(x: x * image.width - 30, y: y * image.height - 30, width: 60, height: 60)
    }

    private func newPlacement() -> PVLivePlacementState {
        PVLivePlacementState()
    }

    private func place(_ target: PVLiveRect, state: inout PVLivePlacementState,
                       in frame: PVLiveRect? = nil, others: [PVLiveRect] = []) -> PVLivePlacement {
        others.withUnsafeBufferPointer { PVPlaceLiveModel(&state, frame ?? image, target, $0.baseAddress, $0.count) }
    }

    private func cg(_ rect: PVLiveRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    @Test func cardUsesOppositeSidesAndIgnoresMidlineJitter() {
        var state = newPlacement()
        #expect(place(target(0.22, 0.23), state: &state).corner == 3)
        for jitter in [0.49, 0.53, 0.46, 0.56, 0.44, 0.51] {
            let card = place(target(jitter, jitter), state: &state)
            #expect(card.corner == 3)
            #expect(cg(card.rect).size == fixedSize)
        }
        #expect(place(target(0.64, 0.53), state: &state).corner == 2)
        #expect(place(target(0.54, 0.64), state: &state).corner == 0)
        #expect(place(target(0.52, 0.48), state: &state).corner == 0)
        #expect(place(target(0.39, 0.48), state: &state).corner == 1)
    }

    @Test func neverCoversTargetOrCameraLetterbox() {
        var state = newPlacement()
        let portrait = PVLiveRect(x: 276, y: 18, width: 344, height: 640)
        let subject = PVLiveRect(x: 288, y: 43, width: 298, height: 335)
        let card = place(subject, state: &state, in: portrait)
        #expect(card.corner == 3)
        #expect(cg(card.rect).size == fixedSize)
        #expect(cg(portrait).contains(cg(card.rect)))
        #expect(!cg(subject).intersects(cg(card.rect)))
        #expect(place(portrait, state: &state, in: portrait).corner == -1)
        #expect(place(PVLiveRect(x: 0, y: 0, width: 22, height: 22), state: &state, in: portrait).corner == -1)
    }

    @Test func findsNearbyClearSpaceAndKeepsItsExactPositionAfterObstacleClears() {
        var state = newPlacement()
        let subject = target(0.22, 0.23)
        let full = place(subject, state: &state)
        let obstacle = PVLiveRect(x: full.rect.x, y: full.rect.y, width: 32, height: full.rect.height)
        let alternate = place(subject, state: &state, others: [obstacle])
        #expect(alternate.corner == full.corner)
        #expect(cg(alternate.rect).size == fixedSize)
        #expect(cg(alternate.rect) != cg(full.rect))
        #expect(!cg(alternate.rect).intersects(cg(obstacle)))
        for sample in 0..<24 {
            let obstructed = sample.isMultiple(of: 2)
            let card = place(subject, state: &state, others: obstructed ? [obstacle] : [])
            #expect(card.corner == full.corner)
            #expect(cg(card.rect) == cg(alternate.rect))
        }
    }

    @Test func hidesWhenTheOppositeSideIsBlockedAndRestoresTheSameOrigin() {
        var state = newPlacement()
        let subject = target(0.22, 0.23)
        let full = place(subject, state: &state)
        let obstacle = PVLiveRect(x: 460, y: 0, width: 740, height: 800)
        #expect(place(subject, state: &state, others: [obstacle]).corner == -1)
        let returned = place(subject, state: &state)
        #expect(returned.corner == full.corner)
        #expect(cg(returned.rect) == cg(full.rect))
    }

    @Test func blockedOppositeQuadrantUsesClearHorizontalHalfAndRetainsOrigin() {
        var state = newPlacement()
        let subject = target(0.22, 0.23)
        let obstacle = PVLiveRect(x: 460, y: 288, width: 740, height: 512)
        let fallback = place(subject, state: &state, others: [obstacle])
        #expect(fallback.corner == 1)
        #expect(cg(fallback.rect).size == fixedSize)
        #expect(!cg(fallback.rect).intersects(cg(obstacle)))
        #expect(cg(place(subject, state: &state).rect) == cg(fallback.rect))
    }

    @Test func nearMidlineCanUseOppositeVerticalHalfWhenHorizontalHalfIsBlocked() {
        var state = newPlacement()
        let subject = target(0.5, 0.23)
        let obstacle = PVLiveRect(x: 460, y: 0, width: 740, height: 800)
        let fallback = place(subject, state: &state, others: [obstacle])
        #expect(fallback.corner == 2)
        #expect(cg(fallback.rect).size == fixedSize)
        #expect(!cg(fallback.rect).intersects(cg(obstacle)))
        let blockBottom = PVLiveRect(x: 0, y: 288, width: 460, height: 512)
        #expect(place(subject, state: &state, others: [obstacle, blockBottom]).corner == -1)
    }

    @Test func newTargetIdentityChangesCornerAndKeepsFixedSize() {
        var state = newPlacement()
        let first = place(target(0.18, 0.21), state: &state)
        state = newPlacement()
        let replacement = place(target(0.78, 0.72), state: &state)
        #expect(first.corner == 3)
        #expect(replacement.corner == 0)
        #expect(cg(first.rect).size == fixedSize)
        #expect(cg(replacement.rect).size == fixedSize)
    }

    @Test func resizingHidesAnUnfitCardAndNeverChangesItsDimensions() {
        var state = newPlacement()
        let subject = target(0.22, 0.23)
        let full = place(subject, state: &state)
        let reduced = PVLiveRect(x: 0, y: 0, width: 640, height: 500)
        let compact = PVLiveRect(x: 0, y: 0, width: 275, height: 220)
        let moved = place(subject, state: &state, in: reduced)
        #expect(moved.corner == full.corner)
        #expect(cg(moved.rect).size == fixedSize)
        #expect(cg(reduced).contains(cg(moved.rect)))
        #expect(place(subject, state: &state, in: compact).corner == -1)
        #expect(cg(place(subject, state: &state).rect) == cg(full.rect))
    }
}
