import Foundation

/// Track IDs in the user's A/B order.
public struct PairSelection: Hashable, Codable {
    public let a: Int
    public let b: Int

    private enum CodingKeys: String, CodingKey { case a, b }

    public init(from decoder: any Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let a = try values.decode(Int.self, forKey: .a)
        let b = try values.decode(Int.self, forKey: .b)
        guard let selection = PairSelection(a, b) else {
            throw DecodingError.dataCorruptedError(forKey: .b, in: values,
                                                   debugDescription: "A and B must be different tracks.")
        }
        self = selection
    }

    public init?(_ a: Int, _ b: Int) {
        guard a != b else { return nil }
        self.a = a
        self.b = b
    }
}

/// Boxes in source-image coordinates normalized to [0, 1], with an upper-left origin.
public struct PairGeometry: Equatable {
    public let selection: PairSelection
    public let received: Double
    public let boxA: Box
    public let boxB: Box

    public init(selection: PairSelection, received: Double, boxA: Box, boxB: Box) {
        self.selection = selection
        self.received = received
        self.boxA = boxA
        self.boxB = boxB
    }

    fileprivate var valid: Bool {
        guard received.isFinite, received >= 0, boxA.valid, boxB.valid else { return false }
        let bounds: ClosedRange<Float> = 0...1
        return [boxA.x1, boxA.y1, boxA.x2, boxA.y2, boxB.x1, boxB.y1, boxB.x2, boxB.y2]
            .allSatisfy(bounds.contains)
    }

    fileprivate func movedSince(_ source: PairGeometry) -> Bool {
        func drifted(_ box: Box, _ previous: Box) -> Bool {
            let centerX = Double((box.x1 + box.x2 - previous.x1 - previous.x2) / 2)
            let centerY = Double((box.y1 + box.y2 - previous.y1 - previous.y2) / 2)
            let areaRatio = max(box.area / previous.area, previous.area / box.area)
            return box.iou(previous) < 0.65 || hypot(centerX, centerY) > 0.04 || areaRatio > 1.35
        }
        return drifted(boxA, source.boxA) || drifted(boxB, source.boxB)
    }

    /// Relative apparent size and changing overlap are cheap risk cues, never an order prediction.
    fileprivate func depthRisk(since source: PairGeometry) -> Bool {
        let a = 0.5 * log(Double(boxA.area) / Double(source.boxA.area))
        let b = 0.5 * log(Double(boxB.area) / Double(source.boxB.area))
        let overlap = Double(boxA.iou(boxB) - source.boxA.iou(source.boxB))
        return abs(a - b) >= 0.21 || max(abs(a), abs(b)) >= 0.29 || abs(overlap) >= 0.18
    }
}

public enum PairOrdering: String, Codable {
    case aCloser, bCloser, tooClose
}

public enum PairRisk: String, Codable {
    case initial, changed, expired, gap, interval
}

public struct PairRequest: Equatable {
    public let source: PairGeometry
    public let reason: PairRisk
    fileprivate let generation: UInt64
    fileprivate let ticket: UInt64
    fileprivate let proposedAt: Double
}

public struct PairMeasurement: Equatable {
    public let request: PairRequest
    public let depthA: Double
    public let depthB: Double

    public init(request: PairRequest, depthA: Double, depthB: Double) {
        self.request = request
        self.depthA = depthA
        self.depthB = depthB
    }

    public var source: PairGeometry { request.source }

    public var ordering: PairOrdering? {
        guard depthA.isFinite, depthB.isFinite, depthA > 0, depthB > 0 else { return nil }
        let tolerance = max(0.05, 0.05 * min(depthA, depthB))
        if abs(depthA - depthB) <= tolerance + 1e-12 { return .tooClose }
        return depthA < depthB ? .aCloser : .bCloser
    }
}

public struct PairDecision: Equatable {
    public let request: PairRequest?
    public let measurement: PairMeasurement?
    public let risk: PairRisk?
    public var ordering: PairOrdering? { measurement?.ordering }
}

public enum PairMode: Equatable {
    case adaptive, baseline, pilotAdaptive, adaptiveImmediate
}

/// Call from one serialized context. Use the same monotonic clock for frame and scheduler times.
public struct PairPolicy {
    private static let interval = 2.0
    private static let adaptiveMaxAge = 3.0
    private static let baselineMaxAge = 5.0
    private static let maxInputAge = 0.75
    private static let maxFrameGap = 0.5
    private static let cooldown = 0.5
    private static let tokenCapacity = 2.0
    private static let confirmationHold = 0.55
    private static let confirmationDeadline = 1.25
    private static let maintenanceAge = 2.75
    private static let maintenanceCredit = 1.4

    public let mode: PairMode
    private var selected: PairSelection?
    private var lastFrame: Double?
    private var lastUpdate: Double?
    private var lastSubmission: Double?
    private var tokens = 1.0
    private var generation: UInt64 = 0
    private var lastTicket: UInt64 = 0
    private var inGap = false
    private var evidenceRisk = PairRisk.initial
    private var changeAnchor: (time: Double, geometry: PairGeometry)?
    private var offered: PairRequest?
    private var pending: PairRequest?
    private var measurement: PairMeasurement?

    public init(mode: PairMode = .adaptive) {
        self.mode = mode
    }

    public mutating func reset() {
        let nextGeneration = generation &+ 1
        self = PairPolicy(mode: mode)
        generation = nextGeneration
    }

    /// Apply selection changes immediately, without resetting the scheduling budget.
    public mutating func setSelection(_ selection: PairSelection?) {
        guard selection != selected else { return }
        selected = selection
        invalidateEvidence(.initial)
        lastFrame = nil
        inGap = false
    }

    /// Read evidence for a displayed frame, which can lag the latest processed frame.
    public func presentation(selection: PairSelection, geometry: PairGeometry, now: Double) -> PairDecision {
        guard selection == selected else {
            return PairDecision(request: nil, measurement: nil, risk: .initial)
        }
        guard isCurrent(geometry, selection: selection, now: now) else {
            return PairDecision(request: nil, measurement: nil, risk: .gap)
        }
        guard let measurement else {
            return PairDecision(request: nil, measurement: nil, risk: evidenceRisk)
        }
        guard measurement.source.received <= geometry.received else {
            return PairDecision(request: nil, measurement: nil, risk: .gap)
        }
        let risk = visibilityRisk(measurement, geometry: geometry, now: now)
        return PairDecision(request: nil, measurement: risk == nil ? measurement : nil, risk: risk)
    }

    /// A proposal does not spend budget or create pending work. Mark it only if accepted by the worker.
    public mutating func update(selection: PairSelection?, geometry: PairGeometry?, now: Double) -> PairDecision {
        offered = nil
        guard now.isFinite, now >= 0 else {
            enterGap()
            return PairDecision(request: nil, measurement: nil, risk: selection == nil ? nil : .gap)
        }
        if let lastUpdate, now < lastUpdate { reset() }
        if let lastUpdate {
            tokens = min(Self.tokenCapacity, tokens + (now - lastUpdate) / Self.interval)
        }
        lastUpdate = now

        setSelection(selection)
        guard let selection else { return PairDecision(request: nil, measurement: nil, risk: nil) }
        guard let geometry, isCurrent(geometry, selection: selection, now: now) else {
            enterGap()
            return PairDecision(request: nil, measurement: nil, risk: .gap)
        }

        if let lastFrame, geometry.received < lastFrame {
            enterGap()
            return PairDecision(request: nil, measurement: nil, risk: .gap)
        }
        if mode != .baseline, let lastFrame, geometry.received - lastFrame > Self.maxFrameGap {
            invalidateEvidence(.gap)
        }
        lastFrame = geometry.received
        inGap = false

        if let pending, hasDepthRisk(geometry, since: pending.source) {
            self.pending = nil
            if measurement == nil { recordChange(now, geometry: geometry) }
        }
        if let measurement, let risk = visibilityRisk(measurement, geometry: geometry, now: now) {
            self.measurement = nil
            if risk == .changed { recordChange(now, geometry: geometry) } else { evidenceRisk = risk }
        }

        let risk = measurement == nil ? evidenceRisk : nil
        let schedule: Bool
        switch mode {
        case .adaptive, .adaptiveImmediate:
            let cooledDown = lastSubmission.map { now - $0 >= Self.cooldown } ?? true
            let needsConfirmation = changeAnchor.map {
                let elapsed = now - $0.time
                return mode == .adaptiveImmediate || elapsed >= Self.confirmationDeadline ||
                    (elapsed >= Self.confirmationHold && geometry.depthRisk(since: $0.geometry))
            } ?? false
            let nearTieRetry = measurement.map {
                $0.ordering == .tooClose && now - $0.source.received >= Self.confirmationHold
            } ?? false
            let maintenance = measurement.map { now - $0.source.received >= Self.maintenanceAge } ?? false
            // Invalidating an old answer is immediate; the measurement waits briefly so that
            // a call can see the other side of the transition. Routine refresh leaves credit.
            if changeAnchor != nil {
                schedule = cooledDown && tokens >= 1 && needsConfirmation
            } else {
                schedule = cooledDown && (tokens >= 1 && (risk != nil || nearTieRetry)
                                          || tokens >= Self.maintenanceCredit && maintenance)
            }
        case .pilotAdaptive:
            let cooledDown = lastSubmission.map { now - $0 >= Self.cooldown } ?? true
            schedule = risk != nil && tokens >= 1 && cooledDown
        case .baseline:
            schedule = lastSubmission.map { now - $0 >= Self.interval } ?? true
        }
        return decision(geometry: geometry, now: now, risk: risk, schedule: schedule)
    }

    @discardableResult
    public mutating func markSubmitted(_ request: PairRequest) -> Bool {
        guard offered == request, pending == nil else { return false }
        offered = nil
        pending = request
        lastTicket = request.ticket
        lastSubmission = request.proposedAt
        if mode != .baseline { tokens -= 1 }
        return true
    }

    @discardableResult
    public mutating func complete(_ measurement: PairMeasurement) -> Bool {
        guard pending == measurement.request else { return false }
        pending = nil
        guard measurement.ordering != nil else { return false }
        self.measurement = measurement
        changeAnchor = nil
        return true
    }

    @discardableResult
    public mutating func fail(_ request: PairRequest) -> Bool {
        guard pending == request else { return false }
        pending = nil
        return true
    }

    private func isCurrent(_ geometry: PairGeometry, selection: PairSelection, now: Double) -> Bool {
        now.isFinite && geometry.selection == selection && geometry.valid &&
            geometry.received <= now && now - geometry.received <= Self.maxInputAge
    }

    private func visibilityRisk(_ measurement: PairMeasurement, geometry: PairGeometry, now: Double) -> PairRisk? {
        if hasDepthRisk(geometry, since: measurement.source) { return .changed }
        let maxAge = mode == .baseline ? Self.baselineMaxAge : Self.adaptiveMaxAge
        return now - measurement.source.received >= maxAge ? .expired : nil
    }

    private func hasDepthRisk(_ geometry: PairGeometry, since source: PairGeometry) -> Bool {
        switch mode {
        case .adaptive, .adaptiveImmediate: return geometry.depthRisk(since: source)
        case .pilotAdaptive: return geometry.movedSince(source)
        case .baseline: return false
        }
    }

    private mutating func recordChange(_ now: Double, geometry: PairGeometry) {
        evidenceRisk = .changed
        if changeAnchor == nil { changeAnchor = (now, geometry) }
    }

    private mutating func decision(geometry: PairGeometry, now: Double, risk: PairRisk?, schedule: Bool) -> PairDecision {
        if schedule, pending == nil {
            offered = PairRequest(source: geometry, reason: risk ?? .interval, generation: generation,
                                  ticket: lastTicket &+ 1, proposedAt: now)
        }
        return PairDecision(request: offered, measurement: measurement, risk: risk)
    }

    private mutating func enterGap() {
        if !inGap, mode != .baseline { invalidateEvidence(.gap) }
        inGap = true
    }

    private mutating func invalidateEvidence(_ risk: PairRisk) {
        generation &+= 1
        offered = nil
        pending = nil
        measurement = nil
        changeAnchor = nil
        evidenceRisk = risk
    }
}
