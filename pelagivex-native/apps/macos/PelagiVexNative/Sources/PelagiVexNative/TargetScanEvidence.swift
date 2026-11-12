#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import PelagiVexCpp
import VisionCore

struct TargetScanColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
}

enum TargetScanMaskSource {
    case instanceMap
    case nativePrototype

    var title: String {
        switch self {
        case .instanceMap: return "实例掩膜"
        case .nativePrototype: return "原生分割掩膜"
        }
    }
}

struct TargetScanShape {
    let width: Int
    let height: Int
    /// Binary mask, row-major from the upper-left of the clipped detection box.
    let mask: [UInt8]
    let fill: Double
    /// Mean of the foreground camera samples in RGB, subject to illumination.
    let averageColor: TargetScanColor?
    let source: TargetScanMaskSource
    let preview: CGImage?
}

struct SingleViewInput: @unchecked Sendable {
    /// Retained, read-only frame from which the silhouette was sampled.
    let pixels: CVPixelBuffer
    /// Detection bounds in normalized, top-left frame coordinates.
    let bounds: CGRect
    let mask: [UInt8]
    let width: Int
    let height: Int
}

struct TargetScanEvidence {
    let trackID: Int
    let sequence: UInt64
    let received: Double
    let pixelWidth: Int
    let pixelHeight: Int
    /// Image area occupied by the clipped detection box, including its background.
    let frameShare: Double
    let shape: TargetScanShape?
    let singleViewInput: SingleViewInput?
}

enum TargetScanEvidenceExtractor {
    /// Extract from one displayed packet on the scan worker's serial background queue.
    static func extract(from packet: Packet, targetID: Int) -> TargetScanEvidence? {
        guard packet.tracks.contains(where: { $0.id == targetID && $0.isObserved }),
              let index = packet.detections.firstIndex(where: { $0.trackID == targetID }) else { return nil }
        let pixels = packet.frame.pixels
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let inputSize = packet.contract?.inputSize ?? 768
        guard width > 0, height > 0, inputSize > 0 else { return nil }
        let transform = Letterbox(width: width, height: height, size: inputSize)
        let box = transform.source(packet.detections[index].box)
        let clipped = Box(max(0, box.x1), max(0, box.y1), min(Float(width), box.x2), min(Float(height), box.y2))
        guard box.valid, clipped.valid else { return nil }
        let boxWidth = clipped.x2 - clipped.x1
        let boxHeight = clipped.y2 - clipped.y1
        let pixelWidth = max(1, Int(boxWidth.rounded()))
        let pixelHeight = max(1, Int(boxHeight.rounded()))
        let shape = makeMask(packet, index: index, transform: transform)
            .flatMap { mask in sample(pixels, box: clipped, pixelWidth: pixelWidth, pixelHeight: pixelHeight, mask: mask) }
        let bounds = CGRect(x: CGFloat(clipped.x1) / CGFloat(width), y: CGFloat(clipped.y1) / CGFloat(height),
                            width: CGFloat(boxWidth) / CGFloat(width), height: CGFloat(boxHeight) / CGFloat(height))
        let singleViewInput = shape.map {
            SingleViewInput(pixels: pixels, bounds: bounds, mask: $0.mask, width: $0.width, height: $0.height)
        }
        return TargetScanEvidence(trackID: targetID, sequence: packet.frame.sequence, received: packet.frame.received,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, frameShare: Double(clipped.area) / (Double(width) * Double(height)),
            shape: shape, singleViewInput: singleViewInput)
    }

    private struct PrototypeMask {
        let values: [Float]
        let boxes: [PVXMaskSampleBox]
        let coefficients: [Float]
        let width: Int
        let height: Int
        let channels: Int
        let transform: Letterbox
    }

    private enum Mask {
        case raster(InstanceMask, label: UInt8)
        case prototype(PrototypeMask)

        var source: TargetScanMaskSource {
            switch self {
            case .raster: return .instanceMap
            case .prototype: return .nativePrototype
            }
        }

        func sample(grid: inout PVXMaskSampleGrid, output: inout PVXMaskSampleOutput) -> Bool {
            switch self {
            case .raster(let raster, let label):
                return raster.pixels.withUnsafeBufferPointer { labels in
                    var input = PVXMaskSampleRaster(labels: labels.baseAddress, count: labels.count,
                                                    width: raster.width, height: raster.height, label: label)
                    return pvxSampleRasterMask(&grid, &input, &output)
                }
            case .prototype(let mask):
                return mask.values.withUnsafeBufferPointer { values in
                    mask.boxes.withUnsafeBufferPointer { boxes in
                        mask.coefficients.withUnsafeBufferPointer { coefficients in
                            var input = PVXMaskSamplePrototypes(values: values.baseAddress, valueCount: values.count,
                                width: mask.width, height: mask.height, channels: mask.channels,
                                scale: mask.transform.scale, padX: mask.transform.padX, padY: mask.transform.padY,
                                inputSize: mask.transform.size, boxes: boxes.baseAddress, boxCount: boxes.count,
                                coefficients: coefficients.baseAddress, coefficientCount: coefficients.count)
                            return pvxSamplePrototypeMask(&grid, &input, &output)
                        }
                    }
                }
            }
        }
    }

    private static func sampleBox(_ box: Box) -> PVXMaskSampleBox {
        PVXMaskSampleBox(x1: box.x1, y1: box.y1, x2: box.x2, y2: box.y2)
    }

    private static func makeMask(_ packet: Packet, index: Int, transform: Letterbox) -> Mask? {
        if let raster = packet.sourceMask {
            guard index < 255 else { return nil }
            return .raster(raster, label: UInt8(index + 1))
        }

        guard !packet.textGuided, let contract = packet.contract else { return nil }
        let width = contract.prototypeWidth, height = contract.prototypeHeight, channels = contract.maskChannels
        guard (1...256).contains(width), (1...256).contains(height), (1...128).contains(channels),
              packet.prototypes.count == width * height * channels else { return nil }
        let target = packet.detections[index]
        guard target.coefficients.count == channels else { return nil }
        let earlier = packet.detections.prefix(index).filter {
            $0.coefficients.count == channels && $0.box.iou(target.box) > 0
        }
        let detections = [target] + earlier
        return .prototype(PrototypeMask(values: packet.prototypes, boxes: detections.map { sampleBox($0.box) },
            coefficients: detections.flatMap(\.coefficients), width: width, height: height, channels: channels,
            transform: transform))
    }

    private static func sample(_ pixels: CVPixelBuffer, box: Box, pixelWidth: Int, pixelHeight: Int,
                               mask: Mask) -> TargetScanShape? {
        let scale = min(1, 64 / Double(max(pixelWidth, pixelHeight)))
        let width = max(1, Int((Double(pixelWidth) * scale).rounded()))
        let height = max(1, Int((Double(pixelHeight) * scale).rounded()))
        let sourceWidth = CVPixelBufferGetWidth(pixels), sourceHeight = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA, rowBytes / 4 >= sourceWidth,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var silhouette = Array(repeating: UInt8(0), count: width * height)
        var rgba = Array(repeating: UInt8(0), count: silhouette.count * 4)
        var grid = PVXMaskSampleGrid(pixels: base, pixelCount: CVPixelBufferGetDataSize(pixels), imageWidth: sourceWidth,
                                     imageHeight: sourceHeight, rowBytes: rowBytes, box: sampleBox(box),
                                     width: width, height: height)
        let sampled: (Int, TargetScanColor)? = silhouette.withUnsafeMutableBufferPointer { maskBytes in
            rgba.withUnsafeMutableBufferPointer { rgbaBytes in
                var output = PVXMaskSampleOutput(silhouette: maskBytes.baseAddress, silhouetteCount: maskBytes.count,
                    rgba: rgbaBytes.baseAddress, rgbaCount: rgbaBytes.count, count: 0, red: 0, green: 0, blue: 0)
                guard mask.sample(grid: &grid, output: &output), output.count >= 4,
                      Int(output.count) * 100 >= maskBytes.count else { return nil }
                let color = TargetScanColor(red: UInt8(output.red / output.count), green: UInt8(output.green / output.count),
                                            blue: UInt8(output.blue / output.count))
                return (Int(output.count), color)
            }
        }
        guard let (count, color) = sampled else { return nil }
        let preview = CGDataProvider(data: Data(rgba) as CFData).flatMap { provider in
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return TargetScanShape(width: width, height: height, mask: silhouette, fill: Double(count) / Double(silhouette.count),
            averageColor: color, source: mask.source, preview: preview)
    }
}
#endif
