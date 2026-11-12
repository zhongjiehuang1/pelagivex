import Foundation
import PelagiVexCpp

public enum PipelineError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

public struct ModelContract: Codable {
    public let schema: Int
    public let format: String
    public let modelName: String?
    public let inputName: String
    public let inputSize: Int
    public let predictionName: String
    public let prototypeName: String
    public let classNames: [String]
    public let maskChannels: Int
    public let prototypeWidth: Int
    public let prototypeHeight: Int
    public let predictionCount: Int
    public var isEndToEnd: Bool { format == "yolo26-e2e-seg" }
    public func validate() throws {
        let legacy = schema == 1 && format == "yolo-v8-11-seg"
        let endToEnd = schema == 2 && isEndToEnd
        guard legacy || endToEnd, !inputName.isEmpty,
              !predictionName.isEmpty, !prototypeName.isEmpty,
              predictionName != prototypeName, (128...1024).contains(inputSize),
              inputSize % 32 == 0, (1...(endToEnd ? 6000 : 2000)).contains(classNames.count),
              classNames.allSatisfy({ !$0.isEmpty }), (1...128).contains(maskChannels),
              (1...256).contains(prototypeWidth), (1...256).contains(prototypeHeight),
              (1...(endToEnd ? 1000 : 30000)).contains(predictionCount) else {
            throw PipelineError.invalid("Unsupported segmentation model contract. Use the verified export adapter for this model.")
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

public struct ClassConfidence: Equatable {
    public let classID: Int
    public let score: Float
    public init(classID: Int, score: Float) { self.classID = classID; self.score = score }
}

public struct Detection {
    public let classID: Int
    public let score: Float
    public let box: Box
    public let coefficients: [Float]
    /// Independent raw class scores, not a normalized or calibrated probability distribution.
    public let classConfidences: [ClassConfidence]
    public var trackID: Int = 0
    public init(classID: Int, score: Float, box: Box, coefficients: [Float],
                classConfidences: [ClassConfidence] = []) {
        self.classID = classID; self.score = score; self.box = box; self.coefficients = coefficients
        self.classConfidences = classConfidences
    }
}

public enum Decoder {
    /// Inspected YOLO26 end-to-end rows: pixel xyxy, winning score, class index, mask coefficients.
    public static func decodeEndToEnd(_ values: [Float], classes: Int, channels: Int, proposals: Int,
                                     confidence: Float = 0.25, limit: Int = 100) throws -> [Detection] {
        try values.withUnsafeBufferPointer {
            try decodeEndToEnd($0, classes: classes, channels: channels, proposals: proposals,
                               confidence: confidence, limit: limit)
        }
    }

    /// The tensor is borrowed for this call. Returned coefficients are owned by each detection.
    public static func decodeEndToEnd(_ values: UnsafeBufferPointer<Float>, classes: Int, channels: Int,
                                     proposals: Int, confidence: Float = 0.25, limit: Int = 100) throws -> [Detection] {
        // The selector validates the tensor before returning original row indices.
        return try withUnsafeTemporaryAllocation(of: Int.self, capacity: 100) { rows in
            let count = PVSelectEndToEndRows(values.baseAddress, values.count, classes, channels,
                                           proposals, confidence, limit, rows.baseAddress)
            guard count >= 0 else {
                throw PipelineError.invalid("Invalid end-to-end segmentation output.")
            }
            let stride = 6 + channels
            return rows.prefix(Int(count)).map { row in
                let offset = row * stride
                let score = values[offset + 4], classID = Int(values[offset + 5])
                let box = Box(values[offset], values[offset + 1], values[offset + 2], values[offset + 3])
                let coefficients = Array(values[(offset + 6)..<(offset + stride)])
                return Detection(classID: classID, score: score, box: box, coefficients: coefficients,
                                 classConfidences: [ClassConfidence(classID: classID, score: score)])
            }
        }
    }

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
            let alternatives = (0..<classes).compactMap { c -> ClassConfidence? in
                let value = values[(4+c)*anchors+a]
                guard value.isFinite, (0...1).contains(value) else { return nil }
                return ClassConfidence(classID: c, score: value)
            }.sorted { $0.score == $1.score ? $0.classID < $1.classID : $0.score > $1.score }
            candidates.append(Detection(classID: cls, score: best, box: box, coefficients: coefficients,
                                        classConfidences: Array(alternatives.prefix(3))))
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

public struct TrackSnapshot {
    public let id: Int
    public let detection: Detection
    public let lastSeen: Double
    public let isObserved: Bool
}

/// Short-term tracking with missed-frame memory and two-stage global association.
/// Retained metadata is separate from current detections: old masks are never propagated.
public final class Tracker {
    private struct Track {
        var detection: Detection
        var lastSeen: Double
        var vx: Float = 0
        var vy: Float = 0
        var hits = 1
        var confirmationCount = 1
        var isConfirmed: Bool
        var acceptedClass: Int
        var pendingClass: Int?
        var pendingClassCount = 0
        var publishedDetection: Detection?
        var lastPublished: Double?
    }
    private static let retention = 0.8
    private static let confirmationWindow = 0.25
    private let confirmationHits: Int
    private let allowClassAgnosticRecovery: Bool
    private var tracks: [Int: Track] = [:]
    private var nextID = 1
    private var lastTime: Double?
    public private(set) var snapshots: [TrackSnapshot] = []
    /// Opt-in confirmation is useful for end-to-end models exposing only a winning label.
    /// Defaults retain the historical immediate-publication/label-supported association.
    public init(confirmationHits: Int = 1, allowClassAgnosticRecovery: Bool = false) {
        precondition((1...5).contains(confirmationHits))
        self.confirmationHits = confirmationHits
        self.allowClassAgnosticRecovery = allowClassAgnosticRecovery
    }
    public func reset() { tracks.removeAll(); lastTime = nil; snapshots = [] }

    public func update(_ items: [Detection], time: Double, newTrackThreshold: Float = 0,
                       maximumMissingSeconds: Double = 0.8, focusedTrackID: Int? = nil) -> [Detection] {
        guard time.isFinite, time >= 0, newTrackThreshold.isFinite, (0...1).contains(newTrackThreshold),
              maximumMissingSeconds.isFinite, (0...4).contains(maximumMissingSeconds) else {
            reset(); return []
        }
        if let lastTime, time < lastTime { reset() }
        lastTime = time
        tracks = tracks.filter { id, track in
            let retention = id == focusedTrackID && track.isConfirmed
                ? max(maximumMissingSeconds, LiveTargetLock.retentionSeconds) : maximumMissingSeconds
            return time - track.lastSeen <= retention
        }
        let valid = items.indices.filter { items[$0].box.valid && items[$0].score.isFinite && (0...1).contains(items[$0].score) }
        let split = max(0.25, newTrackThreshold)
        let high = valid.filter { items[$0].score >= split }
        let low = valid.filter { items[$0].score < split }
        // A winning-label-only model provides no runner-up evidence. Permit a
        // geometry-only label recovery only for a recent, confirmed target with
        // one mutually exclusive, very close high-confidence observation.
        var geometryRecovery: [Int: Int] = [:]
        if allowClassAgnosticRecovery {
            var candidates: [Int: [Int]] = [:]
            var counts: [Int: Int] = [:]
            for index in high {
                let ids = tracks.keys.filter { strongGeometryMatch(items[index], track: tracks[$0]!, time: time) }
                candidates[index] = ids
                for id in ids { counts[id, default: 0] += 1 }
            }
            for (index, ids) in candidates where ids.count == 1 && counts[ids[0]] == 1 {
                geometryRecovery[index] = ids[0]
            }
        }
        var associations: [Int: Int] = [:]
        var available = tracks.keys.sorted()
        for group in [high, low] {
            guard !group.isEmpty, !available.isEmpty else { continue }
            // Each observation has a private dummy column so leaving a target unmatched
            // is always feasible. Hungarian assignment prevents greedy ID stealing.
            let columns = available.count + group.count
            var costs = [Double]()
            costs.reserveCapacity(group.count * columns)
            for index in group {
                for id in available {
                    let track = tracks[id]!
                    let lateFocusedReturn = id == focusedTrackID && time - track.lastSeen > maximumMissingSeconds
                    // After an extended gap, require class agreement and strong overlap
                    // before recovering the lock instead of stealing a nearby identity.
                    if lateFocusedReturn && (items[index].classID != track.detection.classID ||
                        items[index].score < split || items[index].box.iou(track.detection.box) < 0.45) {
                        costs.append(1e6)
                        continue
                    }
                    costs.append(associationCost(items[index], track: track, time: time,
                                                 geometryRecovery: geometryRecovery[index] == id))
                }
                costs.append(contentsOf: repeatElement(0.90, count: group.count))
            }
            var assignment = Array(repeating: columns, count: group.count)
            let assigned = costs.withUnsafeBufferPointer { matrix in
                assignment.withUnsafeMutableBufferPointer { output in
                    PVTrackerAssign(matrix.baseAddress, group.count, columns, output.baseAddress) != 0
                }
            }
            guard assigned else { continue }
            for (row, column) in assignment.enumerated() where column < available.count && costs[row * columns + column] < 0.90 {
                associations[group[row]] = available[column]
            }
            let used = Set(associations.values)
            available.removeAll { used.contains($0) }
        }
        var observed = Set<Int>()
        var updated = Set<Int>()
        var output: [Detection] = []
        for index in valid {
            var item = items[index]
            if let id = associations[index], var track = tracks[id] {
                let dt = time - track.lastSeen
                if dt > 0 {
                    let width = max(1e-6, track.detection.box.x2 - track.detection.box.x1)
                    let height = max(1e-6, track.detection.box.y2 - track.detection.box.y1)
                    let vx = (item.box.x1 + item.box.x2 - track.detection.box.x1 - track.detection.box.x2) / (2 * Float(dt))
                    let vy = (item.box.y1 + item.box.y2 - track.detection.box.y1 - track.detection.box.y2) / (2 * Float(dt))
                    let mix: Float = track.hits == 1 ? 1 : 0.65
                    track.vx = (1-mix) * track.vx + mix * min(width * 8, max(-width * 8, vx))
                    track.vy = (1-mix) * track.vy + mix * min(height * 8, max(-height * 8, vy))
                }
                item.trackID = id
                if !track.isConfirmed {
                    let continued = dt <= Self.confirmationWindow && item.classID == track.detection.classID
                    track.confirmationCount = item.score >= newTrackThreshold
                        ? (continued ? track.confirmationCount + 1 : 1) : 0
                    if track.confirmationCount >= confirmationHits {
                        track.isConfirmed = true
                        track.acceptedClass = item.classID
                    }
                }
                var publish = track.isConfirmed
                if track.isConfirmed && item.classID != track.acceptedClass {
                    let continued = dt <= Self.confirmationWindow && track.pendingClass == item.classID
                    track.pendingClass = item.classID
                    track.pendingClassCount = continued ? track.pendingClassCount + 1 : 1
                    if track.pendingClassCount >= confirmationHits {
                        track.acceptedClass = item.classID
                        track.pendingClass = nil
                        track.pendingClassCount = 0
                    } else {
                        // Keep the ID internally, but do not attach yesterday's label
                        // or confidence to today's different winning-class observation.
                        publish = false
                    }
                } else if item.classID == track.acceptedClass {
                    track.pendingClass = nil
                    track.pendingClassCount = 0
                }
                track.detection = item; track.lastSeen = time; track.hits += 1
                if publish { track.publishedDetection = item; track.lastPublished = time }
                tracks[id] = track
                updated.insert(id)
                guard publish else { continue }
            } else {
                guard item.score >= newTrackThreshold else { continue }
                while tracks[nextID] != nil { nextID = nextID == 1000000 ? 1 : nextID + 1 }
                item.trackID = nextID
                nextID = nextID == 1000000 ? 1 : nextID + 1
                let confirmed = confirmationHits == 1
                tracks[item.trackID] = Track(detection: item, lastSeen: time, isConfirmed: confirmed,
                                            acceptedClass: item.classID,
                                            publishedDetection: confirmed ? item : nil,
                                            lastPublished: confirmed ? time : nil)
                updated.insert(item.trackID)
                guard confirmed else { continue }
            }
            observed.insert(item.trackID)
            output.append(item)
        }
        // A missed inference breaks tentative confirmation. Retaining the internal
        // candidate is harmless; it cannot expose a mask or a confirmed snapshot.
        for id in tracks.keys where !updated.contains(id) {
            tracks[id]!.confirmationCount = 0
            tracks[id]!.pendingClass = nil
            tracks[id]!.pendingClassCount = 0
        }
        // Bound memory even if a moving camera repeatedly reveals unrelated objects.
        if tracks.count > 200 {
            let keep = Set(tracks.keys.sorted {
                let left = tracks[$0]!, right = tracks[$1]!
                if left.isConfirmed != right.isConfirmed { return left.isConfirmed }
                return left.lastSeen == right.lastSeen ? $0 < $1 : left.lastSeen > right.lastSeen
            }.prefix(200))
            tracks = tracks.filter { keep.contains($0.key) }
        }
        snapshots = tracks.keys.sorted().compactMap {
            guard let detection = tracks[$0]!.publishedDetection, let lastSeen = tracks[$0]!.lastPublished else { return nil }
            return TrackSnapshot(id: $0, detection: detection, lastSeen: lastSeen,
                                 isObserved: observed.contains($0))
        }
        return output
    }

    private func strongGeometryMatch(_ item: Detection, track: Track, time: Double) -> Bool {
        let elapsed = time - track.lastSeen
        guard track.isConfirmed, elapsed >= 0, elapsed <= 0.20 else { return false }
        let prior = track.detection.box
        let dt = Float(elapsed)
        let predicted = Box(prior.x1 + track.vx * dt, prior.y1 + track.vy * dt,
                            prior.x2 + track.vx * dt, prior.y2 + track.vy * dt)
        let width = max(1e-6, (predicted.x2-predicted.x1 + item.box.x2-item.box.x1) / 2)
        let height = max(1e-6, (predicted.y2-predicted.y1 + item.box.y2-item.box.y1) / 2)
        let dx = (predicted.x1+predicted.x2-item.box.x1-item.box.x2) / (2*width)
        let dy = (predicted.y1+predicted.y2-item.box.y1-item.box.y2) / (2*height)
        let ratio = max(prior.area/item.box.area, item.box.area/prior.area)
        return predicted.iou(item.box) >= 0.75 && hypot(dx, dy) <= 0.20 && ratio <= 1.5
    }

    private func associationCost(_ item: Detection, track: Track, time: Double,
                                 geometryRecovery: Bool) -> Double {
        let prior = track.detection
        let dt = Float(min(0.4, max(0, time - track.lastSeen)))
        let previous = prior.box
        let predicted = Box(previous.x1 + track.vx * dt, previous.y1 + track.vy * dt,
                            previous.x2 + track.vx * dt, previous.y2 + track.vy * dt)
        let width = max(1e-6, (predicted.x2-predicted.x1 + item.box.x2-item.box.x1) / 2)
        let height = max(1e-6, (predicted.y2-predicted.y1 + item.box.y2-item.box.y1) / 2)
        let dx = (predicted.x1+predicted.x2-item.box.x1-item.box.x2) / (2*width)
        let dy = (predicted.y1+predicted.y2-item.box.y1-item.box.y2) / (2*height)
        let distance = hypot(dx, dy)
        let overlap = max(predicted.iou(item.box), previous.iou(item.box) * 0.9)
        let ratio = max(previous.area/item.box.area, item.box.area/previous.area)
        guard ratio <= 2.5, overlap >= 0.05 || distance <= 0.8 + dt * 0.8 else { return 1e6 }
        let sameClass = item.classID == prior.classID
        if !sameClass {
            let supported = item.classConfidences.contains { $0.classID == prior.classID && $0.score >= 0.10 } ||
                prior.classConfidences.contains { $0.classID == item.classID && $0.score >= 0.10 }
            guard (supported && overlap >= 0.55) || geometryRecovery else { return 1e6 }
        }
        let overlapCost = 0.55 * Double(1-overlap)
        let centerCost = 0.30 * Double(min(distance, 1))
        let sizeCost = 0.10 * abs(log(Double(ratio))) / log(2.5)
        let classCost = sameClass ? 0.0 : 0.12
        let ageCost = 0.02 * (time-track.lastSeen) / Self.retention
        return overlapCost + centerCost + sizeCost + classCost + ageCost
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
