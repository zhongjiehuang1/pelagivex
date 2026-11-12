#if os(macOS)
import Combine
import CoreGraphics
import Foundation

/// The starting analysis belongs to this orbit even if its live track disappears.
/// Each segment starts with the operator confirming the physical subject and view.
final class GuidedOrbitSession: ObservableObject {
    @Published private(set) var target: TargetScanPresentation?
    @Published private(set) var step: GuidedOrbitStep = .front
    @Published private(set) var isRecording = false
    private(set) var recordedAt: Date?

    @discardableResult
    func begin(scan: TargetScanPresentation) -> Bool {
        guard target == nil, scan.phase == .tracking, scan.target?.isObserved == true else { return false }
        recordedAt = Date()
        target = scan
        step = .front
        isRecording = false
        return true
    }

    func toggleCapture(_ capture: ObjectScanCapture) {
        guard target != nil, capture.isCapturing, !capture.isFinishing else { return }
        if isRecording {
            pause(capture)
        } else if capture.guidedCounts[step, default: 0] < ObjectScanCapture.maximumGuidedPhotosPerStep {
            capture.setGuidedStep(step)
            isRecording = true
        }
    }

    func advance(_ capture: ObjectScanCapture) {
        guard target != nil, capture.isCapturing, !capture.isFinishing,
              capture.guidedCounts[step, default: 0] >= GuidedOrbitStep.recommendedPhotos,
              let next = step.next else { return }
        pause(capture)
        step = next
    }

    func pause(_ capture: ObjectScanCapture) {
        capture.setGuidedStep(nil)
        isRecording = false
    }

    func synchronize(_ capture: ObjectScanCapture) {
        guard isRecording else { return }
        if !capture.isCapturing || capture.guidedCounts[step, default: 0] >= ObjectScanCapture.maximumGuidedPhotosPerStep {
            pause(capture)
        }
    }

    func reset() {
        recordedAt = nil
        target = nil
        step = .front
        isRecording = false
    }

    func ready(_ capture: ObjectScanCapture) -> Bool {
        target != nil && capture.folderURL != nil && !capture.isFinishing && GuidedOrbitStep.allCases.allSatisfy {
            capture.guidedCounts[$0, default: 0] >= GuidedOrbitStep.recommendedPhotos
        }
    }

    func advisory(rows: [ObjectRow]) -> String {
        guard let original = target?.target else { return "" }
        guard let current = rows.first(where: { $0.isObserved && $0.id == original.id && $0.name == original.name }) else {
            return "原轨迹暂不可见。请确认镜头仍对准同一物体。"
        }
        let box = current.sourceBox
        if box.minX < 0.02 || box.minY < 0.02 || box.maxX > 0.98 || box.maxY > 0.98 {
            return "原目标靠近画面边缘。请让整个物体留在画面内。"
        }
        return "原目标仍在画面中。绕拍时保持它完整可见。"
    }
}
#endif
