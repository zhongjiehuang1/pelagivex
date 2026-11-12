#if os(macOS)
import CoreVideo
import Foundation
import VisionCore

enum PairDisplayState: Equatable {
    case choose, waitingFrame, missing, measuring, rechecking, tooClose, aCloser, bCloser
}

struct PairPresentation {
    let state: PairDisplayState
    let title: String
    let detail: String
    let localizedTitle: String
    let localizedDetail: String
}

func pairGeometry(_ selection: PairSelection, packet: Packet) -> PairGeometry? {
    guard let contract = packet.contract,
          let a = packet.detections.first(where: { $0.trackID == selection.a }),
          let b = packet.detections.first(where: { $0.trackID == selection.b }) else { return nil }
    let width = CVPixelBufferGetWidth(packet.frame.pixels)
    let height = CVPixelBufferGetHeight(packet.frame.pixels)
    let letterbox = Letterbox(width: width, height: height, size: contract.inputSize)
    func normalized(_ detection: Detection) -> Box {
        let box = letterbox.source(detection.box)
        func clamp(_ value: Float) -> Float { min(1, max(0, value)) }
        return Box(clamp(box.x1 / Float(width)), clamp(box.y1 / Float(height)),
                   clamp(box.x2 / Float(width)), clamp(box.y2 / Float(height)))
    }
    let boxA = normalized(a), boxB = normalized(b)
    guard boxA.valid, boxB.valid else { return nil }
    return PairGeometry(selection: selection, received: packet.frame.received, boxA: boxA, boxB: boxB)
}

/// Serializes pair selection, scheduling and worker completions across the UI and inference queues.
final class PairRuntime {
    private let lock = NSLock()
    private var selection: PairSelection?
    private var adaptive = true
    private var policy = PairPolicy(mode: .adaptive)
    private var revision = 0
    private var submitted = 0

    func setSelection(a: Int?, b: Int?, adaptive: Bool) {
        lock.lock(); defer { lock.unlock() }
        let next = a.flatMap { first in b.flatMap { PairSelection(first, $0) } }
        guard next != selection || adaptive != self.adaptive else { return }
        selection = next
        if adaptive != self.adaptive {
            self.adaptive = adaptive
            policy = PairPolicy(mode: adaptive ? .adaptive : .baseline)
        }
        policy.setSelection(next)
        submitted = 0
        revision += 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        selection = nil
        policy.reset()
        submitted = 0
        revision += 1
    }

    func process(_ packet: Packet, distance: DistanceEstimator, ambientDepthEnabled: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard let selection else {
            if ambientDepthEnabled { distance.submit(packet) }
            return
        }
        let geometry = pairGeometry(selection, packet: packet)
        let decision = policy.update(selection: selection, geometry: geometry, now: ProcessInfo.processInfo.systemUptime)
        guard let request = decision.request else { return }
        let ticket = revision
        if distance.submit(packet, minimumInterval: 0, completion: { [weak self] result in
            self?.complete(request, result: result, revision: ticket)
        }) {
            policy.markSubmitted(request)
            submitted += 1
        }
    }

    private func complete(_ request: PairRequest, result: DistanceResult?, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        guard revision == self.revision else { return }
        let pair = request.source.selection
        if let a = result?.values[pair.a], let b = result?.values[pair.b] {
            policy.complete(PairMeasurement(request: request, depthA: a, depthB: b))
        } else {
            policy.fail(request)
        }
    }

    func presentation(for packet: Packet?, now: Double) -> PairPresentation {
        lock.lock(); defer { lock.unlock() }
        guard let selection else {
            return PairPresentation(state: .choose, title: "Choose two objects", detail: "Select A and B from the analyzed frame.",
                                    localizedTitle: "选择 A 和 B", localizedDetail: "从已分析画面中选择两个目标。")
        }
        let counter = "Depth requests: \(submitted)"
        let localizedCounter = "深度请求 \(submitted) 次"
        guard let packet, now - packet.frame.received <= 0.75 else {
            return PairPresentation(state: .waitingFrame, title: "Waiting for a fresh camera frame", detail: counter,
                                    localizedTitle: "等待新分析画面", localizedDetail: localizedCounter)
        }
        guard let geometry = pairGeometry(selection, packet: packet) else {
            let missing = [(selection.a, "A"), (selection.b, "B")].filter { id, _ in
                !packet.detections.contains(where: { $0.trackID == id })
            }.map(\.1)
            let title = missing.isEmpty ? "Waiting for both tracks" : "Lost track: " + missing.joined(separator: " and ")
            let localizedTitle = missing.isEmpty ? "等待可用的双目标测量" : "暂未跟踪到 " + missing.joined(separator: " 和 ")
            let localizedDetail = missing.isEmpty ? localizedCounter : localizedCounter + " · 若目标以新编号出现，请重新选择。"
            return PairPresentation(state: missing.isEmpty ? .measuring : .missing, title: title,
                                    detail: counter + " · Reselect the object if it returns with a new ID.",
                                    localizedTitle: localizedTitle, localizedDetail: localizedDetail)
        }
        let decision = policy.presentation(selection: selection, geometry: geometry, now: now)
        guard let measurement = decision.measurement, measurement.source.received <= packet.frame.received else {
            let rechecking = decision.risk == .changed || decision.risk == .expired
            return PairPresentation(state: rechecking ? .rechecking : .measuring,
                                    title: rechecking ? "Rechecking the order…" : "Checking depth…", detail: counter,
                                    localizedTitle: rechecking ? "等待复测结果" : "等待深度测量", localizedDetail: localizedCounter)
        }
        let ageSeconds = max(0, now - measurement.source.received)
        let age = String(format: "%.2f s", ageSeconds)
        let detail = counter + " · Evidence age " + age
        let localizedDetail = localizedCounter + String(format: " · 测量取自 %.2f 秒前的画面", ageSeconds)
        switch decision.ordering {
        case .aCloser:
            return PairPresentation(state: .aCloser, title: "A is closer", detail: detail,
                                    localizedTitle: "A 更靠近相机", localizedDetail: localizedDetail)
        case .bCloser:
            return PairPresentation(state: .bCloser, title: "B is closer", detail: detail,
                                    localizedTitle: "B 更靠近相机", localizedDetail: localizedDetail)
        case .tooClose:
            return PairPresentation(state: .tooClose, title: "Too close to call", detail: detail,
                                    localizedTitle: "两者深度太接近", localizedDetail: localizedDetail)
        case nil:
            return PairPresentation(state: .rechecking, title: "Rechecking the order…", detail: detail,
                                    localizedTitle: "等待复测结果", localizedDetail: localizedDetail)
        }
    }
}
#endif
