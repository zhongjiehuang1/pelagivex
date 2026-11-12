import Foundation

/// Selects an observed track for the live card without changing detector or tracker state.
public struct LiveTargetLock {
    public static let retentionSeconds: Double = 1.6
    public struct Candidate {
        public let id: Int
        /// Nil permits an existing lock to follow a weak or partly clipped observation.
        public let priority: Double?

        public init(id: Int, priority: Double?) {
            self.id = id
            self.priority = priority
        }
    }

    private struct Observation {
        let first: Double
        let last: Double
        let count: Int
    }

    private var observations: [Int: Observation] = [:]
    private var sequence: UInt64?
    private var lastObservedAt = -Double.infinity
    public private(set) var reservedID: Int?

    public init() {}

    /// Returns only a current observation. The reserved ID survives a brief
    /// detector dropout so the caller can wait for the same identity.
    public mutating func update(_ candidates: [Candidate], sequence: UInt64?, frameTime: Double?, now: Double) -> Int? {
        guard now.isFinite else { return nil }
        let fresh = frameTime.map { $0.isFinite && now - $0 >= 0 && now - $0 <= 0.45 } ?? false
        let visible = fresh ? candidates : []
        if let sequence, let frameTime, fresh {
            if sequence != self.sequence {
                var next: [Int: Observation] = [:]
                for candidate in visible where candidate.priority?.isFinite == true {
                    if let previous = observations[candidate.id], frameTime > previous.last,
                       frameTime - previous.last <= 0.4 {
                        next[candidate.id] = Observation(first: previous.first, last: frameTime, count: previous.count + 1)
                    } else {
                        next[candidate.id] = Observation(first: frameTime, last: frameTime, count: 1)
                    }
                }
                self.sequence = sequence
                observations = next
            }
        } else {
            observations.removeAll(keepingCapacity: true)
            self.sequence = nil
        }
        if let reservedID, let frameTime, visible.contains(where: { $0.id == reservedID }) {
            lastObservedAt = frameTime
            return reservedID
        }
        if now - lastObservedAt < Self.retentionSeconds { return nil }
        reservedID = nil
        var best: (id: Int, priority: Double)?
        for candidate in visible {
            guard let priority = candidate.priority, priority.isFinite, let observation = observations[candidate.id],
                  observation.count >= 2, observation.last - observation.first >= 0.10 else { continue }
            if let best, priority < best.priority || (priority == best.priority && candidate.id >= best.id) { continue }
            best = (candidate.id, priority)
        }
        guard let best, let frameTime else { return nil }
        reservedID = best.id
        lastObservedAt = frameTime
        return best.id
    }
}
