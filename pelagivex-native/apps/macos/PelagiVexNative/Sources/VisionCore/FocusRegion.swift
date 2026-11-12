import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Normalized, unmirrored source coordinates, with origin at the top left.
public struct FocusRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(x: Double, y: Double, width: Double, height: Double) {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.000001, y + height <= 1.000001 else { return nil }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func containsCenter(of box: CGRect) -> Bool { rect.contains(CGPoint(x: box.midX, y: box.midY)) }

    public static func imageRect(view: CGSize, image: CGSize) -> CGRect {
        guard view.width > 0, view.height > 0, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(view.width / image.width, view.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2, width: size.width, height: size.height)
    }
    public static func selection(start: CGPoint, end: CGPoint, view: CGSize, image: CGSize, mirrored: Bool) -> FocusRegion? {
        let fit = imageRect(view: view, image: image)
        guard !fit.isEmpty, fit.contains(start) else { return nil }
        let clipped = CGPoint(x: min(fit.maxX, max(fit.minX, end.x)), y: min(fit.maxY, max(fit.minY, end.y)))
        let left = min(start.x, clipped.x), top = min(start.y, clipped.y)
        let w = abs(clipped.x - start.x), h = abs(clipped.y - start.y)
        guard w >= 12, h >= 12, w / fit.width >= 0.02, h / fit.height >= 0.02 else { return nil }
        let nx = (left - fit.minX) / fit.width
        return FocusRegion(x: max(0, mirrored ? 1 - nx - w / fit.width : nx),
                           y: (top - fit.minY) / fit.height, width: w / fit.width, height: h / fit.height)
    }
    public func displayRect(view: CGSize, image: CGSize, mirrored: Bool) -> CGRect {
        let fit = Self.imageRect(view: view, image: image)
        return CGRect(x: fit.minX + (mirrored ? 1 - x - width : x) * fit.width,
                      y: fit.minY + y * fit.height, width: width * fit.width, height: height * fit.height)
    }
}
