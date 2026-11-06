import Foundation

public enum PipelineError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public struct ModelContract: Codable {
    public let schema: Int
    public let format: String
    public let inputName: String
    public let inputSize: Int
    public let predictionName: String
    public let prototypeName: String
    public let classNames: [String]
    public let maskChannels: Int
    public let prototypeWidth: Int
    public let prototypeHeight: Int
    public let predictionCount: Int
    public func validate() throws {
        guard schema == 1, format == "yolo-v8-11-seg", !inputName.isEmpty,
              !predictionName.isEmpty, !prototypeName.isEmpty,
              predictionName != prototypeName, (128...1024).contains(inputSize),
              inputSize % 32 == 0, (1...2000).contains(classNames.count),
              classNames.allSatisfy({ !$0.isEmpty }), (1...128).contains(maskChannels),
              (1...256).contains(prototypeWidth), (1...256).contains(prototypeHeight),
              (1...30000).contains(predictionCount) else {
            throw PipelineError.invalid("Unsupported model contract. Use scripts/export_model.py, not a detection-only model.")
        }
    }
}

public struct Box: Equatable {
    public var x1: Float, y1: Float, x2: Float, y2: Float
    public init(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }
    public var valid: Bool { [x1,y1,x2,y2].allSatisfy(\.isFinite) && x2 > x1 && y2 > y1 }
    public var area: Float { max(0, x2-x1) * max(0, y2-y1) }
    public func iou(_ b: Box) -> Float {
        let overlap = max(0, min(x2,b.x2)-max(x1,b.x1)) * max(0, min(y2,b.y2)-max(y1,b.y1))
        return overlap / max(area+b.area-overlap, 1e-9)
    }
}

/// Pixel coordinates, origin at the upper left. No camera mirroring in inference.
public struct Letterbox {
    public let scale: Float, padX: Float, padY: Float, size: Float
    public init(width: Int, height: Int, size: Int) {
        precondition(width > 0 && height > 0 && size > 0)
        self.size = Float(size)
        scale = min(Float(size)/Float(width), Float(size)/Float(height))
        padX = (Float(size)-Float(width)*scale)/2
        padY = (Float(size)-Float(height)*scale)/2
    }
    public func source(_ box: Box) -> Box {
        Box((box.x1-padX)/scale, (box.y1-padY)/scale, (box.x2-padX)/scale, (box.y2-padY)/scale)
    }
}

public struct Detection {
    public let classID: Int
    public let score: Float
    public let box: Box
    public let coefficients: [Float]
    public var trackID: Int = 0
    public init(classID: Int, score: Float, box: Box, coefficients: [Float]) {
        self.classID = classID; self.score = score; self.box = box; self.coefficients = coefficients
    }
}

public enum Decoder {
    /// Dense channel-major tensor [1, 4+classes+maskChannels, anchors]. Scores are probabilities.
    public static func decode(_ values: [Float], classes: Int, channels: Int, anchors: Int,
                              confidence: Float = 0.35, iou: Float = 0.5, limit: Int = 25) throws -> [Detection] {
        guard classes > 0, channels > 0, anchors > 0, anchors <= 30000,
              classes <= 2000, channels <= 128, limit > 0, limit <= 100,
              confidence.isFinite, confidence >= 0, confidence <= 1,
              iou.isFinite, iou >= 0, iou <= 1,
              values.count == (4+classes+channels)*anchors else {
            throw PipelineError.invalid("Invalid segmentation tensor shape or decoding options.")
        }
        var candidates = [Detection]()
        for a in 0..<anchors {
            var best: Float = -1; var cls = 0
            for c in 0..<classes {
                let score = values[(4+c)*anchors+a]
                if score.isFinite && score <= 1 && score > best { best = score; cls = c }
            }
            guard best >= confidence else { continue }
            let x = values[a], y = values[anchors+a], w = values[2*anchors+a], h = values[3*anchors+a]
            let box = Box(x-w/2,y-h/2,x+w/2,y+h/2)
            guard box.valid else { continue }
            let coefficients = (0..<channels).map { values[(4+classes+$0)*anchors+a] }
            guard coefficients.allSatisfy(\.isFinite) else { continue }
            candidates.append(Detection(classID: cls, score: best, box: box, coefficients: coefficients))
        }
        candidates.sort { $0.score > $1.score }
        var selected = [Detection]()
        // Bounded NMS cost even when an incompatible/noisy model predicts thousands of boxes.
        for item in candidates.prefix(1000) {
            if !selected.contains(where: { $0.classID == item.classID && $0.box.iou(item.box) > iou }) {
                selected.append(item)
                if selected.count == limit { break }
            }
        }
        return selected
    }
}

/// A lightweight, class-aware IoU tracker. Not re-identification or mask propagation.
public final class Tracker {
    private var previous: [Detection] = []
    private var nextID = 1
    private var lastTime: Double = 0
    public init() {}
    public func reset() { previous = []; lastTime = 0 }
    public func update(_ items: [Detection], time: Double) -> [Detection] {
        if time-lastTime > 0.5 || time < lastTime { previous = [] }
        var used = Set<Int>()
        let output = items.map { item -> Detection in
            var item = item
            let match = previous.enumerated().filter { !used.contains($0.offset) && $0.element.classID == item.classID }
                .max { $0.element.box.iou(item.box) < $1.element.box.iou(item.box) }
            if let match, match.element.box.iou(item.box) >= 0.3 {
                used.insert(match.offset); item.trackID = match.element.trackID
            } else { item.trackID = nextID; nextID = nextID == 1000000 ? 1 : nextID+1 }
            return item
        }
        previous = output; lastTime = time; return output
    }
}

/// One producer/worker hand-off: at most one waiting value, replacing stale input.
public final class LatestSlot<T> {
    private let lock = NSLock()
    private var pending: T?
    private var workerActive = false
    public init() {}
    public func offer(_ value: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending = value
        if workerActive { return false }
        workerActive = true; return true
    }
    public func take() -> T? {
        lock.lock(); defer { lock.unlock() }
        if let value = pending { pending = nil; return value }
        workerActive = false; return nil
    }
    public func clear() { lock.lock(); pending = nil; lock.unlock() }
}

public final class Snapshot<T> {
    private let lock = NSLock()
    private var value: T?
    public init() {}
    public func set(_ value: T?) { lock.lock(); self.value = value; lock.unlock() }
    public func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Rolling, bounded measurements from actual unique frames, not UI timer ticks.
public final class FrameMeter {
    private let lock = NSLock()
    private var samples: [(UInt64,Double,Double)] = []
    public init() {}
    public func add(sequence: UInt64, finished: Double, received: Double) {
        lock.lock(); defer { lock.unlock() }
        guard finished.isFinite, received.isFinite, finished >= received,
              samples.last?.0 != sequence else { return }
        samples.append((sequence,finished,(finished-received)*1000))
        if samples.count > 120 { samples.removeFirst(samples.count-120) }
    }
    public func reset() { lock.lock(); samples = []; lock.unlock() }
    public func read() -> (fps: Double, p95MS: Double, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last else { return (0,0,0) }
        let elapsed = last.1-first.1
        let sorted = samples.map { $0.2 }.sorted()
        return (elapsed > 0 ? Double(samples.count-1)/elapsed : 0,
                sorted[max(0,Int(ceil(Double(sorted.count)*0.95))-1)],samples.count)
    }
}
