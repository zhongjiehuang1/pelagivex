import Foundation
import PelagiVexCpp

/// An instance-label raster in source-image coordinates. Zero is background.
public struct InstanceMask {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let representedInstances: Set<UInt8>

    public init(width: Int, height: Int, pixels: [UInt8], instanceCount: Int) throws {
        guard (1...2048).contains(width), (1...2048).contains(height),
              (0...255).contains(instanceCount), pixels.count == width * height else {
            throw PipelineError.invalid("Invalid source-image instance mask.")
        }
        let representedInstances = try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { present in
            let valid = pixels.withUnsafeBufferPointer {
                pvxDiscoverInstanceLabels($0.baseAddress, $0.count, UInt8(instanceCount), present.baseAddress)
            }
            guard valid else { throw PipelineError.invalid("Invalid source-image instance mask.") }
            return Set(present.indices.lazy.filter { present[$0] != 0 }.map { UInt8($0) })
        }
        self.width = width; self.height = height; self.pixels = pixels
        self.representedInstances = representedInstances
    }

    /// Drop rejected detections and map retained IDs into the current draw order.
    public func remapped(_ lookup: [UInt8], instanceCount: Int) throws -> InstanceMask {
        guard lookup.first == 0, representedInstances.allSatisfy({ Int($0) < lookup.count }) else {
            throw PipelineError.invalid("Incomplete instance-mask remapping.")
        }
        return try InstanceMask(width: width, height: height, pixels: pixels.map { lookup[Int($0)] },
                                instanceCount: instanceCount)
    }
}
