import Testing
@testable import VisionCore

struct InstanceMaskTests {
    @Test func filteredDetectionsNeverLeaveWrongMaskColors() throws {
        let original = try InstanceMask(width: 3, height: 2, pixels: [0, 1, 2, 3, 1, 2], instanceCount: 3)
        let filtered = try original.remapped([0, 2, 0, 1], instanceCount: 2)
        #expect(filtered.pixels == [0, 2, 0, 1, 2, 0])
        #expect(filtered.width == 3 && filtered.height == 2)
    }
    @Test func invalidRastersAndIncompleteMapsAreRejected() throws {
        #expect(throws: (any Error).self) { try InstanceMask(width: 0, height: 2, pixels: [], instanceCount: 0) }
        #expect(throws: (any Error).self) { try InstanceMask(width: 2, height: 2, pixels: [0], instanceCount: 0) }
        #expect(throws: (any Error).self) { try InstanceMask(width: 1, height: 1, pixels: [2], instanceCount: 1) }
        let mask = try InstanceMask(width: 1, height: 1, pixels: [2], instanceCount: 2)
        #expect(throws: (any Error).self) { try mask.remapped([0, 1], instanceCount: 1) }
        #expect(throws: (any Error).self) { try mask.remapped([1, 1, 1], instanceCount: 1) }
    }
}
