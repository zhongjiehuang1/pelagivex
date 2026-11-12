import Foundation
import PelagiVexCpp

/// Advances suggested viewpoints using capture time and accepted photos. The stage names are
/// instructions to the operator. The policy does not estimate camera pose or angular coverage.
public struct AutoOrbitPolicy {
    public enum Stage: Int, CaseIterable, Hashable, Sendable {
        case front, firstSide, back, secondSide, upper
    }

    public enum Decision: Equatable, Sendable {
        case keepCapturing, reconstruct, needsMoreViews
    }

    public static let minimumPhotos = Int(PVAutoOrbitPolicyMinimumPhotos)
    public static let samplesPerStage = Int(PVAutoOrbitPolicySamplesPerStage)
    public static let automaticPhotos = Int(PVAutoOrbitPolicyAutomaticPhotos)

    private var state = PVAutoOrbitPolicyState()

    public var stage: Stage { Stage(rawValue: Int(state.stage)) ?? .front }

    public init() {}

    public mutating func start(at now: TimeInterval) {
        PVAutoOrbitPolicyStart(&state, now)
    }

    public mutating func pause(at now: TimeInterval) {
        PVAutoOrbitPolicyPause(&state, now)
    }

    public mutating func resume(at now: TimeInterval) {
        PVAutoOrbitPolicyResume(&state, now)
    }

    public func elapsed(at now: TimeInterval) -> TimeInterval {
        PVAutoOrbitPolicyElapsed(state, now)
    }

    /// Counts only photos the capture worker has accepted and written to the input folder.
    /// Read the new stage after each call and use it to label subsequent samples.
    public mutating func update(acceptedPhotos: Int, acceptedByStage: [Stage: Int],
                                at now: TimeInterval) -> Decision {
        let counts = PVAutoOrbitPhotoCounts(front: Int64(acceptedByStage[.front, default: 0]),
                                            firstSide: Int64(acceptedByStage[.firstSide, default: 0]),
                                            back: Int64(acceptedByStage[.back, default: 0]),
                                            secondSide: Int64(acceptedByStage[.secondSide, default: 0]),
                                            upper: Int64(acceptedByStage[.upper, default: 0]))
        switch PVAutoOrbitPolicyUpdate(&state, Int64(acceptedPhotos), counts, now) {
        case PVAutoOrbitPolicyReconstruct: return .reconstruct
        case PVAutoOrbitPolicyNeedsMoreViews: return .needsMoreViews
        default: return .keepCapturing
        }
    }
}
