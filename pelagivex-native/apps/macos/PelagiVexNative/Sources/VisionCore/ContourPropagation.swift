import Foundation
import PelagiVexCpp

/// Association and affine geometry for reusing a recent contour on a newly detected object.
/// Indices refer to detection-array order, while both boxes are normalized source-image boxes.
public struct ContourWarp: Equatable {
    public let sourceIndex: Int
    public let currentIndex: Int
    public let sourceBox: Box
    public let currentBox: Box

    public func sourcePoint(for point: SIMD2<Float>) -> SIMD2<Float>? {
        guard point.x >= currentBox.x1, point.x < currentBox.x2,
              point.y >= currentBox.y1, point.y < currentBox.y2 else { return nil }
        return SIMD2(sourceBox.x1 + (point.x-currentBox.x1)/(currentBox.x2-currentBox.x1)*(sourceBox.x2-sourceBox.x1),
                     sourceBox.y1 + (point.y-currentBox.y1)/(currentBox.y2-currentBox.y1)*(sourceBox.y2-sourceBox.y1))
    }
}

public enum ContourPropagation {
    public static let defaultMaximumAge: Double = 0.65

    public static func normalizedSourceBox(_ detection: Detection, width: Int, height: Int,
                                           inputSize: Int) -> Box? {
        guard width > 0, height > 0, inputSize > 0 else { return nil }
        var normalized = PVContourBox()
        let geometry = sourceGeometry(width: width, height: height, inputSize: inputSize)
        guard PVContourNormalizedBox(rawBox(detection.box), geometry, &normalized) != 0 else { return nil }
        return box(normalized)
    }

    /// A positive, unambiguous track ID, stable class and conservative geometry are all required.
    /// Wall-clock expiry also prevents a paused detector from displaying a fine contour indefinitely.
    public static func warps(source: [Detection], current: [Detection],
                             sourceWidth: Int, sourceHeight: Int, currentWidth: Int, currentHeight: Int,
                             inputSize: Int, sourceReceived: Double, currentReceived: Double, now: Double,
                             maximumAge: Double = defaultMaximumAge) -> [ContourWarp] {
        let frameAge = currentReceived-sourceReceived, wallAge = now-sourceReceived
        guard !source.isEmpty, !current.isEmpty, inputSize > 0,
              sourceWidth > 0, sourceHeight > 0, currentWidth > 0, currentHeight > 0,
              maximumAge.isFinite, maximumAge >= 0, frameAge.isFinite, wallAge.isFinite,
              frameAge >= 0, frameAge <= maximumAge, wallAge >= 0, wallAge <= maximumAge else { return [] }
        let sourceAspect = Double(sourceWidth)/Double(sourceHeight)
        let currentAspect = Double(currentWidth)/Double(currentHeight)
        guard abs(currentAspect/sourceAspect-1) <= 0.02 else { return [] }
        let old = source.map(rawDetection)
        let new = current.map(rawDetection)
        let sourceGeometry = sourceGeometry(width: sourceWidth, height: sourceHeight, inputSize: inputSize)
        let currentGeometry = Self.sourceGeometry(width: currentWidth, height: currentHeight, inputSize: inputSize)
        return withUnsafeTemporaryAllocation(of: PVContourWarp.self, capacity: min(old.count, new.count, 255)) { result in
            let count = PVContourMatch(old, old.count, sourceGeometry, new, new.count, currentGeometry, result.baseAddress)
            return result.prefix(count).map { match in
                ContourWarp(sourceIndex: match.sourceIndex, currentIndex: match.currentIndex,
                            sourceBox: box(match.sourceBox), currentBox: box(match.currentBox))
            }
        }
    }

    private static func sourceGeometry(width: Int, height: Int, inputSize: Int) -> PVContourGeometry {
        let transform = Letterbox(width: width, height: height, size: inputSize)
        return PVContourGeometry(width: Float(width), height: Float(height), scale: transform.scale,
                                 padX: transform.padX, padY: transform.padY)
    }

    private static func rawDetection(_ detection: Detection) -> PVContourDetection {
        PVContourDetection(trackID: Int64(detection.trackID), classID: Int64(detection.classID), box: rawBox(detection.box))
    }

    private static func rawBox(_ box: Box) -> PVContourBox {
        PVContourBox(x1: box.x1, y1: box.y1, x2: box.x2, y2: box.y2)
    }

    private static func box(_ raw: PVContourBox) -> Box {
        Box(raw.x1, raw.y1, raw.x2, raw.y2)
    }
}
