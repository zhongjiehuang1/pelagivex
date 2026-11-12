#if os(macOS)
import AppKit
import AVFoundation
import CoreVideo
import SwiftUI
import VisionCore

/// The camera stays mounted and keeps processing while the overlay consumes the
/// last completed display packet. Model generation never submits a camera scan.
@MainActor
struct LiveCameraView: View {
    let controller: AppController
    let onWorkbench: () -> Void
    @StateObject private var model = LiveModelController()
    @State private var lock = LiveTargetLock()
    @State private var frameSize = CGSize.zero
    @State private var latestSequence: UInt64?
    @State private var isFresh = false
    @State private var target: LiveOverlayTarget?
    @State private var targetObserved = false
    @State private var lastObservedTargetTime = -Double.infinity
    @State private var obstacles: [CGRect] = []
    @State private var placement = LiveOverlayPlacementTelemetry(visible: false, quadrant: nil)
    private let clock = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()

    private static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let sceneLabels: Set<String> = [
        "background", "darkness", "scene", "room", "wall", "floor", "ceiling", "ground", "sky", "road"
    ]

    private var wireframe: LiveWireframeModel? {
        guard let target, let current = model.model, current.trackID == target.trackID else { return nil }
        return current
    }

    var body: some View {
        ZStack {
            MetalSurface(controller: controller)
            cameraGestureSurface
            if !controller.error.isEmpty {
                Text(controller.running ? "识别中断" : "摄像头不可用")
                    .font(.system(size: 13, weight: .medium)).help(controller.error)
                    .allowsHitTesting(false)
            } else if controller.loading || (controller.running && !isFresh) {
                ProgressView().controlSize(.small).accessibilityLabel("等待摄像头画面")
                    .allowsHitTesting(false)
            } else if !controller.running {
                Text("轻点画面开启摄像头")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .allowsHitTesting(false)
            }
            LiveCameraOverlay(frameSize: frameSize, mirrored: controller.mirror, isLive: isFresh,
                              target: target, targetObserved: targetObserved, obstacles: obstacles, modelReady: wireframe != nil,
                              onPlacement: { next in
                if placement != next { placement = next }
                report()
            }) {
                if let wireframe { LiveWireframeView(model: wireframe, zoom: model.zoom) }
            }
        }
        .background(.black)
        .onAppear { refresh() }
        .onReceive(clock) { _ in refresh() }
        .onChange(of: wireframe?.sequence) { _, _ in report() }
        .onChange(of: controller.liveCameraMode) { _, enabled in
            if enabled { refresh() } else { resetLivePresentation() }
        }
        .overlay(alignment: .topLeading) {
            Button(action: toggleCamera) {
                Color.clear.frame(width: 96, height: 42).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.running ? "停止摄像头" : "开启摄像头")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(controller.loading)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                cameraMenu
            } label: {
                Color.clear.frame(width: 86, height: 42).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("摄像头选项")
            .padding(.trailing, 8)
        }
        .onDisappear(perform: resetLivePresentation)
    }

    /// A sibling beneath the wireframe so video input never steals its drag or pinch.
    private var cameraGestureSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { toggleFullScreen() }
                .exclusively(before: TapGesture().onEnded {
                    if !controller.running { controller.start() }
                }))
            .contextMenu { cameraMenu }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var cameraMenu: some View {
        Button(controller.running ? "停止摄像头" : "开启摄像头", action: toggleCamera)
            .disabled(controller.loading)
        Button("切换全屏", action: toggleFullScreen)
        Picker("摄像头来源", selection: Binding(get: { controller.cameraChoice }, set: { controller.cameraChoice = $0 })) {
            Text("自动").tag("auto")
            ForEach(controller.cameras, id: \.uniqueID) { camera in
                Text(camera.localizedName).tag(camera.uniqueID)
            }
        }
        .disabled(controller.running)
        if controller.efficientModelAvailable {
            Picker("性能配置", selection: Binding(get: { controller.performanceProfile },
                                               set: { controller.changePerformanceProfile($0) })) {
                Text("参考精度").tag(RecognitionPerformance.reference)
                Text("高效预览").tag(RecognitionPerformance.efficient)
            }
            .disabled(controller.running || controller.loading)
        }
        Toggle("SAM 精细描边", isOn: Binding(get: { controller.refineBoundaries }, set: { controller.refineBoundaries = $0 }))
        Toggle("镜像", isOn: Binding(get: { controller.mirror }, set: { controller.mirror = $0 }))
        Divider()
        Button("高级工作台…", action: onWorkbench)
    }

    private func toggleCamera() {
        if controller.running { controller.stop() } else { controller.start() }
    }

    private func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    private func resetLivePresentation() {
        model.reset()
        lock = LiveTargetLock()
        frameSize = .zero
        latestSequence = nil
        isFresh = false
        targetObserved = false
        lastObservedTargetTime = -.infinity
        setTarget(nil)
        controller.setLiveOverlayTarget(nil)
        obstacles = []
        controller.observeLiveOverlay(.init(active: false))
    }

    private func refresh() {
        guard controller.liveCameraMode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previousReservation = lock.reservedID
        guard controller.error.isEmpty, let packet = controller.renderer?.displayedObjects.get()?.0,
              now - packet.frame.received >= 0, now - packet.frame.received <= 0.45 else {
            _ = lock.update([], sequence: nil, frameTime: nil, now: now)
            if previousReservation != lock.reservedID { model.reset() }
            controller.setLiveOverlayTarget(lock.reservedID)
            latestSequence = nil
            isFresh = false
            targetObserved = false
            setTarget(nil)
            if !obstacles.isEmpty { obstacles = [] }
            report()
            return
        }
        if !isFresh { isFresh = true }
        guard latestSequence != packet.frame.sequence else { return }
        latestSequence = packet.frame.sequence
        let width = CVPixelBufferGetWidth(packet.frame.pixels)
        let height = CVPixelBufferGetHeight(packet.frame.pixels)
        let size = CGSize(width: width, height: height)
        if size != frameSize {
            model.reset()
            lock = LiveTargetLock()
            lastObservedTargetTime = -.infinity
            frameSize = size
        }
        let transform = Letterbox(width: width, height: height, size: packet.contract?.inputSize ?? 768)
        let observed = packet.tracks.compactMap { track -> LiveOverlayTarget? in
            let item = track.detection
            guard track.isObserved, track.id > 0, item.box.valid, packet.names.indices.contains(item.classID) else { return nil }
            let box = transform.source(item.box)
            let rect = CGRect(x: CGFloat(box.x1) / size.width, y: CGFloat(box.y1) / size.height,
                              width: CGFloat(box.x2 - box.x1) / size.width, height: CGFloat(box.y2 - box.y1) / size.height)
                .intersection(Self.fullFrame)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            let name = packet.names[item.classID]
            guard packet.textGuided || !Self.sceneLabels.contains(name.lowercased()) else { return nil }
            return LiveOverlayTarget(trackID: track.id, name: name, confidence: item.score, rect: rect)
        }
        let candidates = observed.map { row in
            LiveTargetLock.Candidate(id: row.trackID, priority: priority(row, size: size))
        }
        let visible = lock.update(candidates, sequence: packet.frame.sequence, frameTime: packet.frame.received, now: now)
        if previousReservation != lock.reservedID { model.reset() }
        controller.setLiveOverlayTarget(lock.reservedID)
        let selected = observed.first { $0.trackID == visible }
        targetObserved = selected != nil
        if let selected {
            lastObservedTargetTime = packet.frame.received
            setTarget(selected)
            model.update(packet: packet, targetID: selected.trackID)
        } else if target?.trackID != lock.reservedID || now - lastObservedTargetTime > 0.35 {
            setTarget(nil)
        }
        let nextObstacles = observed.filter { $0.trackID != lock.reservedID && $0.confidence >= 0.35 &&
            !Self.sceneLabels.contains($0.name.lowercased()) &&
            $0.rect.width * $0.rect.height < 0.70 }.map(\.rect)
        if obstacles != nextObstacles { obstacles = nextObstacles }
        report()
    }

    private func setTarget(_ next: LiveOverlayTarget?) {
        if target?.trackID != next?.trackID {
            placement = LiveOverlayPlacementTelemetry(visible: false, quadrant: nil)
        }
        if target != next { target = next }
    }

    private func priority(_ row: LiveOverlayTarget, size: CGSize) -> Double? {
        let rect = row.rect
        let area = rect.width * rect.height
        guard row.confidence >= 0.40, area >= 0.012, area <= 0.70,
              rect.width * size.width >= 24, rect.height * size.height >= 24 else { return nil }
        let centrality = max(0, 1 - hypot(rect.midX - 0.5, rect.midY - 0.5) / 0.7)
        return 0.46 * min(1, sqrt(Double(area) / 0.28)) + 0.36 * Double(row.confidence) + 0.18 * centrality
    }

    private func report() {
        guard controller.liveCameraMode, controller.recordsLiveOverlayMetrics else { return }
        let current = wireframe
        controller.observeLiveOverlay(.init(active: true, targetID: target?.trackID,
            modelReady: current != nil, cardVisible: current != nil && placement.visible,
            cardSlot: placement.quadrant, cardWidth: placement.width, cardHeight: placement.height,
            modelFieldOfView: current.flatMap { model.zoom.presentedFieldOfView(for: $0) },
            zoomFieldOfView: Double(model.zoom.fieldOfView)))
    }
}
#endif
