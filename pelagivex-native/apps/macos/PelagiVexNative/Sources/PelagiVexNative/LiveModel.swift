#if os(macOS)
import AppKit
import SceneKit
import SwiftUI

struct LiveWireframeModel: Sendable {
    let trackID: Int
    let sequence: UInt64
    fileprivate let mesh: SingleViewPrediction.MemoryMesh
    var usedDepth: Bool { mesh.usedDepth }
}

/// The user's lens setting belongs to the live view, not to a mesh or card.
@MainActor
final class LiveWireframeZoom {
    private(set) var fieldOfView: CGFloat = 36
    private weak var presentedView: SCNView?
    private var presentedTrackID: Int?
    private var presentedSequence: UInt64?

    func adjust(by logarithmicChange: CGFloat) {
        guard logarithmicChange.isFinite else { return }
        let change = max(-2, min(2, logarithmicChange))
        fieldOfView = max(14, min(68, fieldOfView * exp(change)))
    }

    func recordPresentation(_ view: SCNView, model: LiveWireframeModel) {
        presentedView = view
        presentedTrackID = model.trackID
        presentedSequence = model.sequence
    }

    func presentedFieldOfView(for model: LiveWireframeModel) -> Double? {
        guard presentedTrackID == model.trackID, presentedSequence == model.sequence,
              let presentedView, presentedView.window != nil, !presentedView.isHiddenOrHasHiddenAncestor,
              let lens = presentedView.pointOfView?.camera else { return nil }
        return Double(lens.fieldOfView)
    }
}

/// Builds at most one volume per lock from the displayed packet's own silhouette.
/// The model is kept in memory, separate from recorded scans and the export workflow.
@MainActor
final class LiveModelController: ObservableObject {
    @Published private(set) var model: LiveWireframeModel?
    let zoom = LiveWireframeZoom()
    private var trackID: Int?
    private var cachedModel: LiveWireframeModel?
    private var targetIsVisible = false
    private var revision = 0
    private var task: Task<Void, Never>?
    private var lastAttempt = -Double.infinity
    private var attemptedSequence: UInt64?

    func update(packet: Packet, targetID: Int?) {
        if trackID != targetID {
            reset()
            trackID = targetID
        }
        let now = ProcessInfo.processInfo.systemUptime
        let age = now - packet.frame.received
        guard let targetID, age >= 0, age <= (packet.textGuided ? 5 : 0.75),
              packet.tracks.contains(where: { $0.id == targetID && $0.isObserved }) else {
            targetIsVisible = false
            if model != nil { model = nil }
            return
        }
        targetIsVisible = true
        if let cachedModel {
            if model == nil { model = cachedModel }
            return
        }
        guard task == nil, packet.frame.sequence != attemptedSequence, now - lastAttempt >= 1.5 else { return }

        let ticket = revision
        lastAttempt = now
        attemptedSequence = packet.frame.sequence
        task = Task.detached(priority: .utility) { [weak self] in
            let result = Self.build(packet: packet, targetID: targetID)
            let cancelled = Task.isCancelled
            await self?.complete(cancelled ? nil : result, revision: ticket)
        }
    }

    func reset() {
        revision += 1
        task?.cancel()
        trackID = nil
        targetIsVisible = false
        cachedModel = nil
        if model != nil { model = nil }
        lastAttempt = -.infinity
        attemptedSequence = nil
    }

    private func complete(_ result: LiveWireframeModel?, revision ticket: Int) {
        task = nil
        guard ticket == revision, let result, result.trackID == trackID else { return }
        cachedModel = result
        if targetIsVisible { model = result }
    }

    private nonisolated static func build(packet: Packet, targetID: Int) -> LiveWireframeModel? {
        guard !Task.isCancelled,
              let input = TargetScanEvidenceExtractor.extract(from: packet, targetID: targetID)?.singleViewInput else {
            return nil
        }
        // The thumbnail needs fewer triangles than the full-size export viewer.
        let mesh = (try? SingleViewPrediction.liveMesh(compact(input))) ?? (try? SingleViewPrediction.liveMesh(input))
        guard let mesh else { return nil }
        return LiveWireframeModel(trackID: targetID, sequence: packet.frame.sequence, mesh: mesh)
    }

    private nonisolated static func compact(_ input: SingleViewInput) -> SingleViewInput {
        let maximum = max(input.width, input.height)
        guard maximum > 40 else { return input }
        let width = max(1, input.width * 40 / maximum)
        let height = max(1, input.height * 40 / maximum)
        let mask = (0..<height).flatMap { row in
            (0..<width).map { column in
                let x = (2 * column + 1) * input.width / (2 * width)
                let y = (2 * row + 1) * input.height / (2 * height)
                return input.mask[y * input.width + x]
            }
        }
        return SingleViewInput(pixels: input.pixels, bounds: input.bounds, mask: mask, width: width, height: height)
    }
}

/// SceneKit animates just the visible wireframe card at its own frame rate.
struct LiveWireframeView: NSViewRepresentable {
    let model: LiveWireframeModel
    let zoom: LiveWireframeZoom

    final class Coordinator {
        var trackID: Int?
        var sequence: UInt64?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiveWireframeSceneView {
        let view = LiveWireframeSceneView(frame: .zero, zoom: zoom)
        view.backgroundColor = .clear
        view.rendersContinuously = false
        view.isPlaying = false
        view.preferredFramesPerSecond = 15
        view.antialiasingMode = .none
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.inertiaEnabled = false
        view.setAccessibilityLabel("自动旋转的预测 3D 线框，拖动调整视角，滚轮或双指捏合缩放")
        return view
    }

    func updateNSView(_ view: LiveWireframeSceneView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.trackID != model.trackID || coordinator.sequence != model.sequence else { return }
        coordinator.trackID = model.trackID
        coordinator.sequence = model.sequence

        let source = SCNGeometrySource(data: model.mesh.positions, semantic: .vertex, vectorCount: model.mesh.vertexCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0, dataStride: 3 * MemoryLayout<Float>.stride)
        let elements = SCNGeometryElement(data: model.mesh.indices, primitiveType: .triangles,
            primitiveCount: model.mesh.triangleCount, bytesPerIndex: MemoryLayout<UInt32>.stride)
        let geometry = SCNGeometry(sources: [source], elements: [elements])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(srgbRed: 0.20, green: 0.74, blue: 1, alpha: 1)
        material.fillMode = .lines
        geometry.firstMaterial = material
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let meshNode = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(meshNode)

        let camera = SCNNode()
        let lens = SCNCamera()
        lens.fieldOfView = zoom.fieldOfView
        lens.zNear = 0.01
        lens.zFar = 20
        camera.camera = lens
        camera.position = SCNVector3(1.12, 0.52, 2.08)
        let center = SCNVector3(0, 0, 0)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        view.defaultCameraController.pointOfView = camera
        view.defaultCameraController.target = center
        view.rotateModel(meshNode)
        zoom.recordPresentation(view, model: model)
    }

    static func dismantleNSView(_ view: LiveWireframeSceneView, coordinator: Coordinator) {
        view.stopRotation()
    }
}

final class LiveWireframeSceneView: SCNView {
    private static let rotationKey = "live-wireframe-turn"
    private let zoom: LiveWireframeZoom
    private weak var rotatingMesh: SCNNode?

    init(frame: NSRect, zoom: LiveWireframeZoom) {
        self.zoom = zoom
        super.init(frame: frame, options: nil)
    }

    required init?(coder: NSCoder) { nil }

    func rotateModel(_ mesh: SCNNode) {
        stopRotation()
        rotatingMesh = mesh
        // The live volume is already centered on the origin. Turn its mesh
        // independently of the user's orbit camera and zoom preference.
        let turn = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 24)
        turn.timingMode = .linear
        mesh.runAction(.repeatForever(turn), forKey: Self.rotationKey)
        isPlaying = window != nil
    }

    func stopRotation() {
        rotatingMesh?.removeAction(forKey: Self.rotationKey)
        rotatingMesh = nil
        isPlaying = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPlaying = window != nil && rotatingMesh != nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let scale = event.hasPreciseScrollingDeltas ? 0.012 : 0.10
        applyZoom(-delta * scale)
    }

    override func magnify(with event: NSEvent) {
        let delta = event.magnification
        guard delta > -1, delta != 0 else { return }
        // SceneKit's default pinch moves the camera. Use the shared lens instead
        // so the same zoom can be restored after the card is hidden or remounted.
        applyZoom(-log1p(delta))
    }

    private func applyZoom(_ change: CGFloat) {
        guard change.isFinite, let camera = pointOfView?.camera else { return }
        zoom.adjust(by: change)
        camera.fieldOfView = zoom.fieldOfView
        needsDisplay = true
    }
}
#endif
