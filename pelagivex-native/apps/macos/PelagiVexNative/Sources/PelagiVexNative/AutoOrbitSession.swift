#if os(macOS)
import Combine
import CoreGraphics
import Foundation
import VisionCore

/// Drives the automatic workflow on the main actor. Sampling and reconstruction own their workers.
@MainActor
final class AutoOrbitSession: ObservableObject {
    @Published private(set) var phase: AutoOrbitPanel.Phase?
    @Published private(set) var step: GuidedOrbitStep = .front
    @Published private(set) var targetName: String?
    @Published private(set) var guidance = ""

    private var policy = AutoOrbitPolicy()
    private var target: TargetScanPresentation?
    private var recordedAt: Date?
    private var inputFolder: URL?
    private var openedCamera = false
    private var waitingForFrame = false
    private var waitingForSilhouetteSince: Double?
    private var cancelRequested = false
    private var runID = UUID()

    var active: Bool { phase != nil }

    func start(controller: AppController) {
        guard !active else { return }
        phase = .searching
        guidance = "把物体完整放在画面中央。锁定后，保持角度可生成体积，也可以绕拍。"
        openedCamera = !controller.running
        controller.focusSelecting = false
        controller.startTargetScan(aimed: true)
        if !controller.running { fail("无法启动摄像头。请检查当前采集源。") }
    }

    func tick(controller: AppController, reconstruction: ObjectReconstruction,
              now: Double = ProcessInfo.processInfo.systemUptime) {
        let capture = controller.objectCapture
        switch phase {
        case .searching:
            guard controller.running, controller.error.isEmpty else {
                controller.stopTargetScan()
                fail(controller.error.isEmpty ? "摄像头已停止。" : controller.error)
                return
            }
            let scan = controller.targetScan
            guard fresh(controller), scan.phase == .tracking, let row = scan.target, row.isObserved,
                  let width = controller.telemetry.frameWidth, let height = controller.telemetry.frameHeight else {
                waitingForSilhouetteSince = nil
                return
            }
            // Let the scan worker obtain a mask before freezing the lock-frame evidence.
            // Multi-view capture is still possible for detections without a usable mask.
            if scan.singleViewInput == nil {
                if waitingForSilhouetteSince == nil { waitingForSilhouetteSince = now }
                guard now - (waitingForSilhouetteSince ?? now) >= 2.5 else {
                    setGuidance("已锁定物体，正在提取轮廓。")
                    return
                }
            }
            capture.start(region: nil, source: controller.telemetry.capturedSource ?? controller.selectedCameraName,
                          imageSize: CGSize(width: width, height: height), automatic: true)
            guard capture.isCapturing, let folder = capture.folderURL else {
                controller.stopTargetScan()
                fail(capture.message)
                return
            }
            target = scan
            if scan.singleViewInput != nil {
                Task(priority: .utility) { await SingleViewPrediction.prepareDepth() }
            }
            targetName = row.name
            recordedAt = Date()
            inputFolder = folder
            controller.stopTargetScan()
            policy.start(at: now)
            capture.setGuidedStep(.front)
            phase = .capturing
            setGuidance(step.automaticInstruction)
        case .capturing:
            if !controller.error.isEmpty { capture.stop(); fail(controller.error); return }
            guard capture.isCapturing else { fail(capture.message); return }
            guard fresh(controller) else {
                if !waitingForFrame {
                    waitingForFrame = true
                    policy.pause(at: now)
                    capture.setGuidedStep(nil)
                }
                setGuidance("等待摄像头恢复新画面，画面恢复后会继续采集。")
                return
            }
            if waitingForFrame {
                waitingForFrame = false
                policy.resume(at: now)
                capture.setGuidedStep(step)
            }
            if policy.stage == .front, policy.elapsed(at: now) >= 5,
               capture.unchangedSamples >= 5, (1...2).contains(savedCount(capture)),
               target?.singleViewInput != nil {
                reconstruct(controller: controller, reconstruction: reconstruction, singleView: true)
                return
            }
            let counts = Dictionary(uniqueKeysWithValues: AutoOrbitPolicy.Stage.allCases.map { stage in
                let correspondingStep = GuidedOrbitStep(rawValue: stage.rawValue) ?? .front
                return (stage, capture.guidedCounts[correspondingStep, default: 0])
            })
            let decision = policy.update(acceptedPhotos: capture.count, acceptedByStage: counts, at: now)
            if decision == .reconstruct {
                reconstruct(controller: controller, reconstruction: reconstruction)
                return
            }
            if let next = GuidedOrbitStep(rawValue: policy.stage.rawValue), next != step {
                step = next
                capture.setGuidedStep(next)
            }
            let hasSingleViewOption = step == .front && target?.singleViewInput != nil && savedCount(capture) <= 2
            let instruction = step == .front && !hasSingleViewOption
                ? "保持物体静止，从当前角度缓慢向一侧移动。" : step.automaticInstruction
            setGuidance(decision == .needsMoreViews && capture.automaticQuality == nil
                ? "还需要新的视角。\(instruction)" : instruction)
        case .paused:
            if !controller.error.isEmpty { capture.stop(); fail(controller.error) }
            else if !capture.isCapturing { fail(capture.message) }
        case .reconstructing, .failed, nil:
            break
        }
    }

    func pause(_ capture: ObjectScanCapture) {
        guard phase == .capturing else { return }
        capture.setGuidedStep(nil)
        policy.pause(at: ProcessInfo.processInfo.systemUptime)
        phase = .paused
        setGuidance("照片已保留。恢复时从刚才的角度继续绕拍。")
    }

    func resume(_ controller: AppController) {
        guard phase == .paused, controller.objectCapture.isCapturing else { return }
        phase = .capturing
        waitingForFrame = true // The next fresh frame re-arms the same stage.
    }

    func savedCount(_ capture: ObjectScanCapture) -> Int {
        inputFolder != nil && capture.folderURL == inputFolder ? capture.count : 0
    }

    func canFinish(_ capture: ObjectScanCapture) -> Bool {
        !capture.isFinishing && savedCount(capture) >= AutoOrbitPolicy.minimumPhotos
    }

    func reconstruct(controller: AppController, reconstruction: ObjectReconstruction, singleView: Bool = false) {
        let capture = controller.objectCapture
        let input = singleView ? target?.singleViewInput : nil
        let ready = singleView ? input != nil && savedCount(capture) > 0 && !capture.isFinishing : canFinish(capture)
        guard phase == .capturing || phase == .paused || phase == .failed, ready,
              !reconstruction.isBusy, let target, let recordedAt else { return }
        phase = .reconstructing
        setGuidance("正在写入最后一张照片。")
        capture.setGuidedStep(nil)
        let ticket = runID
        capture.finish { [weak self] folder in
            guard let self, self.runID == ticket, self.phase == .reconstructing else { return }
            guard let folder, folder == self.inputFolder else { self.fail("找不到这次采集的照片。"); return }
            let analysis = ModelScanAnalysis.from(target, at: recordedAt, counts: capture.guidedCounts,
                                                  automatic: true, singleView: singleView)
            let output = folder.deletingLastPathComponent().appendingPathComponent("model-\(UUID().uuidString.prefix(8)).usdz")
            controller.stop()
            if let input, let analysis {
                reconstruction.startSingleView(input: input, outputURL: output, linkedAnalysis: analysis)
            } else {
                reconstruction.start(inputFolder: folder, outputURL: output, detail: .reduced, sequential: true, linkedAnalysis: analysis)
            }
            self.reconstructionChanged(reconstruction)
        }
    }

    func reconstructionChanged(_ reconstruction: ObjectReconstruction) {
        guard phase == .reconstructing else { return }
        switch reconstruction.state {
        case .completed: reset()
        case .cancelled: if cancelRequested { reset() } else { fail(reconstruction.message) }
        case .failed: fail(reconstruction.message)
        default: break
        }
    }

    func cancel(controller: AppController, reconstruction: ObjectReconstruction) {
        if phase == .reconstructing && !controller.objectCapture.isFinishing {
            guard reconstruction.state == .preparing || reconstruction.state == .running else { return }
            cancelRequested = true
            reconstruction.cancel()
            return
        }
        let shouldStopCamera = openedCamera
        reset()
        controller.stopTargetScan()
        controller.objectCapture.stop()
        if shouldStopCamera { controller.stop() }
    }

    func reset() {
        runID = UUID()
        phase = nil
        step = .front
        target = nil
        targetName = nil
        recordedAt = nil
        inputFolder = nil
        waitingForFrame = false
        waitingForSilhouetteSince = nil
        cancelRequested = false
        openedCamera = false
    }

    private func fresh(_ controller: AppController) -> Bool {
        guard controller.running, controller.error.isEmpty, let age = controller.telemetry.frameAgeSeconds else { return false }
        return age.isFinite && age <= (controller.recognitionMode == .fast ? 0.75 : 5)
    }

    private func fail(_ message: String) {
        setGuidance(message)
        phase = .failed
    }

    private func setGuidance(_ message: String) {
        if guidance != message { guidance = message }
    }
}

private extension GuidedOrbitStep {
    var automaticInstruction: String {
        switch self {
        case .front: "保持当前角度几秒以预测体积，或缓慢移动镜头开始绕拍。"
        case .firstSide: "沿原方向绕到侧面，让相邻画面仍有重叠。"
        case .back: "继续沿同方向绕向背面，保持同一物体完整可见。"
        case .secondSide: "沿另一侧回向起点，继续缓慢移动。"
        case .upper: "稍微抬高镜头并向下倾斜，沿弧线补拍顶部。"
        }
    }
}
#endif
