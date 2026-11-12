#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import CoreML
import CoreVideo
import MetalKit
import VisionCore

struct ObjectPairChoice: Equatable {
    var a: Int?
    var b: Int?
    var adaptive = true
}

enum RecognitionPerformance: String { case reference, efficient }

struct ObjectRow: Identifiable {
    let id: Int
    let name: String
    let confidence: Float
    let color: SIMD4<Float>?
    let depth: Double?
    let isObserved: Bool
    let secondsSinceSeen: Double
    let otherClassScores: String
    let sourceBox: CGRect
}

final class AppController: ObservableObject {
    @Published var status = "Ready. Click Start Camera to begin."
    @Published var modelStatus = "Local recognition model is not loaded."
    @Published var error = ""
    @Published var running = false
    @Published private(set) var liveCameraMode = false
    @Published var loading = false
    @Published var mirror = false
    @Published var showFineOutlines = true
    @Published var outlineWidth = 1.5
    @Published var refineBoundaries = true {
        didSet {
            pipeline.refineContours.set(refineBoundaries)
            if oldValue != refineBoundaries { resetTelemetry() }
        }
    }
    @Published var metrics = "No measurements yet"
    @Published private(set) var telemetry = ConsoleTelemetry()
    @Published var objects: [ObjectRow] = []
    @Published private(set) var targetScan = TargetScanPresentation(phase: .idle)
    private let targetScanSession = TargetScanSession()
    @Published private(set) var focusRegion: FocusRegion?
    @Published var focusSelecting = false
    @Published var reconstructionBusy = false
    let objectCapture = ObjectScanCapture()
    var focusedObjects: [ObjectRow] {
        guard let focusRegion else { return objects }
        return objects.filter { focusRegion.containsCenter(of: $0.sourceBox) }
    }
    func setFocus(_ region: FocusRegion?) {
        guard !objectCapture.isCapturing, !objectCapture.isFinishing, !reconstructionBusy else { return }
        if focusRegion != region { targetScanSession.reset() }
        focusRegion = region; focusSelecting = false; clearPair()
    }
    @Published var classCount = 0
    @Published private(set) var performanceProfile = RecognitionPerformance.reference
    var efficientModelAvailable: Bool {
        Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("EfficientModel/model.json").path) } ?? false
    }
    @Published private(set) var recognitionMode: RecognitionMode = .fast
    @Published var promptDraft = "computer monitor, desk, cabinet, charging cable, headphones, keys, pen, tissue box, power socket, water bottle, chair, person"
    @Published private(set) var activePrompts = ["computer monitor", "desk", "cabinet", "charging cable", "headphones", "keys", "pen", "tissue box", "power socket", "water bottle", "chair", "person"]
    @Published private(set) var promptError = ""
    @Published private(set) var recognitionStatus = "Fast objects: local segmentation"
    @Published private(set) var analyzedFrameAge = "Waiting for an analyzed frame"
    @Published var minimumConfidence = 0.25 {
        didSet { pipeline.minimumConfidence.set(Float(minimumConfidence)) }
    }
    @Published var distanceStatus = "Distance: waiting for an object"
    @Published private(set) var pairChoice = ObjectPairChoice()
    @Published private(set) var pairPresentation: PairPresentation?
    var isDepthRequested: Bool {
        (pipeline.ambientDepthEnabled.get() ?? true) || (pairChoice.a != nil && pairChoice.b != nil)
    }
    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraChoice = UserDefaults.standard.string(forKey: "cameraChoice") ?? "auto" {
        didSet {
            UserDefaults.standard.set(cameraChoice, forKey: "cameraChoice")
            if oldValue != cameraChoice { setFocus(nil) }
        }
    }
    var selectedCameraName: String {
        if cameraChoice == "auto" { return "Automatic" }
        return cameras.first { $0.uniqueID == cameraChoice }?.localizedName ?? "Selected camera unavailable"
    }
    let pipeline = Pipeline()
    let camera = Camera()
    let device = MTLCreateSystemDefaultDevice()
    var renderer: Renderer?
    private var timer: Timer?
    private var generation = 0
    private var permissionPending = false
    private var lastDeviceScan = 0.0
    private var telemetrySince = ProcessInfo.processInfo.systemUptime
    private let liveBenchmark = CamoLiveBenchmark.fromCommandLine()

    init() {
        if let device {
            do { renderer = try Renderer(device: device, pipeline: pipeline) }
            catch { self.error = error.localizedDescription }
        } else { error = "Metal is not available on this Mac." }
        camera.onFrame = { [weak self] frame in
            self?.objectCapture.offer(frame)
            self?.pipeline.submit(frame)
        }
        camera.onState = { [weak self] text in DispatchQueue.main.async {
            self?.status = text
            if text.hasPrefix("Camera error:") { self?.stop(); self?.error = text }
        } }
        pipeline.onError = { [weak self] text in DispatchQueue.main.async {
            guard let self else { return }
            self.error = "Recognition stopped: \(text)"
            if self.recognitionMode == .fast { self.modelStatus = "Model error. Restart the app to reload the segmenter." }
        } }
        renderer?.onError = { [weak self] text in DispatchQueue.main.async { self?.error = text } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        refreshCameras()
        let initialProfile = liveBenchmark?.profile ?? .reference
        let modelDirectory = initialProfile == .efficient ? "EfficientModel" : "Model"
        if let root = Bundle.main.resourceURL?.appendingPathComponent(modelDirectory),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("model.json").path) {
            load(root, profile: initialProfile)
        }
    }
    private func load(_ folder: URL, profile: RecognitionPerformance) {
        guard !running, !loading, let device else { return }
        loading = true; error = ""; status = "Compiling and loading the Core ML model…"
        let compute: MLComputeUnits = profile == .efficient ? .cpuAndGPU : .all
        pipeline.load(folder: folder, compute: compute, device: device) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.loading = false }
                switch result {
                case .success(let info):
                    self.performanceProfile = profile
                    self.updateDepthDemand()
                    self.classCount = info.classes
                    self.modelStatus = "\(info.name) · loaded"
                    self.status = "Model ready. Click Start Camera."
                case .failure(let error):
                    self.error = error.localizedDescription
                    self.status = "Model loading failed."
                }
            }
        }
    }
    func changePerformanceProfile(_ profile: RecognitionPerformance) {
        guard !running, !loading, performanceProfile != profile,
              profile == .reference || efficientModelAvailable,
              let resources = Bundle.main.resourceURL else { return }
        clearPair(); pipeline.stop(); objects = []
        resetTelemetry()
        load(resources.appendingPathComponent(profile == .efficient ? "EfficientModel" : "Model"), profile: profile)
    }
    func start() { start(liveView: true) }
    func start(liveView: Bool) { start(deviceID: cameraChoice, liveView: liveView) }

    func start(deviceID: String, liveView: Bool = true) {
        guard !running, !loading, !objectCapture.isFinishing, !reconstructionBusy, renderer != nil else { return }
        if error.hasPrefix("Camera error:") || error.hasPrefix("Camera access denied") { error = "" }
        resetTelemetry()
        generation += 1; let ticket = generation
        running = true; permissionPending = true
        setLiveCameraMode(liveView)
        status = "Starting the selected camera…"
        func proceed(_ granted: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == ticket else { return }
                self.permissionPending = false
                guard granted else { self.stop(); self.error = "Camera access denied. Allow PelagiVex in System Settings → Privacy & Security → Camera."; return }
                self.renderer?.displayMeter.reset(); self.pipeline.active.set(ticket); self.camera.start(deviceID: deviceID)
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: proceed(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: proceed)
        default: proceed(false)
        }
    }
    func stop() {
        objectCapture.stop()
        stopTargetScan()
        generation += 1; running = false; permissionPending = false
        setLiveCameraMode(false)
        resetTelemetry()
        clearPair()
        pipeline.stop(); camera.stop(); renderer?.displayMeter.reset(); objects = []; metrics = "Stopped"
        distanceStatus = "Distance: waiting for an object"
    }
    func startTargetScan(aimed: Bool = false) {
        guard !loading, !reconstructionBusy, !objectCapture.isFinishing, renderer != nil else { return }
        if !running { start(liveView: false) }
        guard running else { return }
        targetScanSession.start(aimed: aimed)
        updateDepthDemand()
        targetScan = TargetScanPresentation(phase: .searching)
    }
    func stopTargetScan() {
        guard targetScanSession.isActive else { return }
        targetScanSession.stop()
        updateDepthDemand()
        targetScan = TargetScanPresentation(phase: .idle)
    }
    func shuffleTargetScan() {
        guard targetScan.canShuffle else { return }
        targetScanSession.shuffle()
        refresh()
    }
    func setPairChoice(_ choice: ObjectPairChoice) {
        guard choice != pairChoice, choice.a == nil || choice.a != choice.b else { return }
        pipeline.comparison.setSelection(a: choice.a, b: choice.b, adaptive: choice.adaptive)
        pairChoice = choice
        pairPresentation = nil
        refresh()
    }
    func clearPair() {
        setPairChoice(ObjectPairChoice(a: nil, b: nil, adaptive: pairChoice.adaptive))
    }
    private func updateDepthDemand() {
        let ambient = !liveCameraMode && (performanceProfile == .reference || targetScanSession.isActive)
        pipeline.ambientDepthEnabled.set(CamoLiveBenchmark.ambientDepthOverride ?? ambient)
    }
    func setLiveCameraMode(_ enabled: Bool) {
        guard liveCameraMode != enabled, !enabled || running else { return }
        if enabled {
            stopTargetScan()
            focusSelecting = false
        }
        liveCameraMode = enabled
        renderer?.liveStyle.set(enabled ? Renderer.LiveStyle(trackID: nil) : nil)
        pipeline.liveFocusTrackID.set(nil)
        updateDepthDemand()
    }
    func setLiveOverlayTarget(_ id: Int?) {
        if liveCameraMode, renderer?.liveStyle.get()?.trackID != id {
            renderer?.liveStyle.set(Renderer.LiveStyle(trackID: id))
            pipeline.liveFocusTrackID.set(id)
        }
    }
    func observeLiveOverlay(_ state: CamoLiveBenchmark.LiveOverlayState) {
        liveBenchmark?.observeLiveOverlay(state)
    }
    var recordsLiveOverlayMetrics: Bool { liveBenchmark != nil }
    private func validatedPrompts() -> [String]? {
        let fields = promptDraft.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "\n", with: ",").split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...32).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              Set(fields.map { $0.lowercased() }).count == fields.count else {
            promptError = "Enter 1–32 distinct English category names, separated by commas; each name must have 1–128 characters."
            return nil
        }
        promptError = ""
        return fields
    }
    func changeRecognitionMode(_ mode: RecognitionMode) {
        guard mode != recognitionMode else { return }
        let prompts: [String]
        if mode == .text {
            guard let parsed = validatedPrompts() else { return }
            prompts = parsed
        } else { prompts = activePrompts }
        applyRecognition(mode: mode, prompts: prompts)
    }
    func applyPrompts() {
        guard let prompts = validatedPrompts() else { return }
        applyRecognition(mode: .text, prompts: prompts)
    }
    private func applyRecognition(mode: RecognitionMode, prompts: [String]) {
        clearPair()
        targetScanSession.reset()
        recognitionMode = mode
        activePrompts = prompts
        objects = []
        resetTelemetry()
        renderer?.displayMeter.reset()
        analyzedFrameAge = "Waiting for the new recognition mode"
        error = ""
        pipeline.setRecognition(mode: mode, prompts: prompts)
        recognitionStatus = pipeline.recognitionStatus.get() ?? (mode == .text ? "Preparing local text-guided recognition…" : "Fast objects: local segmentation")
        refresh()
    }
    private func resetTelemetry() {
        telemetrySince = ProcessInfo.processInfo.systemUptime
        telemetry = ConsoleTelemetry()
    }
    private func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { liveBenchmark?.tick(self, at: now) }
        if now - lastDeviceScan > 2 { refreshCameras() }
        renderer?.mirrored = mirror
        renderer?.outlineWidth = showFineOutlines ? Float(outlineWidth) : 0
        recognitionStatus = pipeline.recognitionStatus.get() ?? recognitionStatus
        guard running, !permissionPending else { return }
        let c = pipeline.captureMeter.read(), i = pipeline.inferenceMeter.read(), d = renderer?.displayMeter.read()
        let packet = pipeline.packets.get()
        let displayed = renderer?.displayedObjects.get()
        let colors = displayed?.1 ?? [:]
        let displayedPacket = (displayed?.0).flatMap { packet -> Packet? in
            guard packet.textGuided == (recognitionMode == .text),
                  !packet.textGuided || packet.names == activePrompts else { return nil }
            return packet
        }
        analyzedFrameAge = displayedPacket.map { String(format: "Analyzed frame age %.2f s", max(0, now - $0.frame.received)) }
            ?? "Waiting for an analyzed frame"
        let distance = pipeline.distance.result.get()
        let fresh = distance.map { now - $0.received < 5 } ?? false
        if recognitionMode == .text {
            distanceStatus = "Detailed contours · local recognition. Depth comparison is available in Fast objects."
        } else if isDepthRequested {
            distanceStatus = pipeline.distance.status.get() ?? "Distance: waiting for an object"
        } else {
            distanceStatus = "选择 A/B 或启动目标分析后测深。"
        }
        objects = displayedPacket.map { packet in
            func name(_ classID: Int) -> String {
                packet.names.indices.contains(classID) ? packet.names[classID] : "Unknown class"
            }
            return packet.tracks.map { track in
                let detection = track.detection
                let observed = track.isObserved && now - packet.frame.received <= (packet.sourceMask != nil ? 5.0 : 0.75)
                let alternatives = detection.classConfidences.filter { $0.classID != detection.classID }.map {
                    String(format: "%@ %.1f%%", name($0.classID), Double($0.score) * 100)
                }.joined(separator: " · ")
                let width = CVPixelBufferGetWidth(packet.frame.pixels)
                let height = CVPixelBufferGetHeight(packet.frame.pixels)
                let source = Letterbox(width: width, height: height, size: packet.contract?.inputSize ?? 768).source(detection.box)
                let sourceBox = CGRect(x: Double(source.x1) / Double(width), y: Double(source.y1) / Double(height),
                    width: Double(source.x2 - source.x1) / Double(width), height: Double(source.y2 - source.y1) / Double(height))
                return ObjectRow(id: track.id, name: name(detection.classID), confidence: detection.score,
                                 color: observed ? colors[track.id] : nil,
                                 depth: observed && fresh && !packet.textGuided ? distance?.values[track.id] : nil,
                                 isObserved: observed, secondsSinceSeen: max(0, now - track.lastSeen),
                                 otherClassScores: alternatives, sourceBox: sourceBox)
            }.sorted { $0.id < $1.id }
        } ?? []
        pairPresentation = recognitionMode == .fast ? pipeline.comparison.presentation(for: displayedPacket, now: now) : nil
        let renderMeasurement = renderer?.measurements.get()
        let gpu = renderMeasurement?.gpuMS ?? 0
        let sam = pipeline.contourRefiner.meter.read()
        let refined = pipeline.contourRefiner.result.get()
        let coverage = renderer?.contourCoverage.get()
        let samEnabled = refineBoundaries && recognitionMode == .fast
        let samInfo = samEnabled
            ? refined.map { String(format: "\nSAM refresh %.1f FPS · Worker %.0f ms · Result age %.2f s · Fine %d/%d targets", sam.fps, $0.workerMS, max(0, now - $0.received), coverage?.refined ?? 0, coverage?.total ?? 0) }
                ?? "\nSAM: preparing fine contours…"
            : ""
        metrics = String(format: "Capture %.1f FPS · Inference %.1f FPS · Display %.1f FPS\nPreprocess %.1f ms · Model %.1f ms · Postprocess %.1f ms\nMetal %.1f ms · Callback to GPU P95 %.1f ms", c.fps,i.fps,d?.fps ?? 0,
                         packet?.preprocessMS ?? 0,packet?.inferenceMS ?? 0,packet?.postprocessMS ?? 0,gpu,d?.p95MS ?? 0) + samInfo

        let visibleSample: Packet? = displayedPacket.flatMap {
            $0.frame.received >= telemetrySince ? $0 : nil
        }
        if targetScanSession.isActive {
            let candidates = targetScanSession.aimedSelection ? objects : focusedObjects
            targetScan = targetScanSession.update(rows: candidates, packet: error.isEmpty ? visibleSample : nil,
                                                  distance: distance, now: now)
        }
        let analysisSample: Packet? = packet.flatMap {
            guard $0.frame.received >= telemetrySince, $0.textGuided == (recognitionMode == .text),
                  $0.textGuided ? $0.names == activePrompts : $0.contract != nil else { return nil }
            return $0
        }
        let samSample: RefinedFrame? = refined.flatMap { samEnabled && $0.received >= telemetrySince ? $0 : nil }
        let currentCoverage = samEnabled && visibleSample != nil ? coverage : nil
        telemetry = ConsoleTelemetry(
            captureFPS: c.count >= 2 ? c.fps : nil,
            detectionFPS: analysisSample != nil && i.count >= 2 ? i.fps : nil,
            displayFPS: visibleSample != nil && (d?.count ?? 0) >= 2 ? d?.fps : nil,
            samFPS: samSample != nil && sam.count >= 2 ? sam.fps : nil,
            samWorkerMS: samSample?.workerMS,
            samAgeSeconds: samSample.map { max(0, now - $0.received) },
            frameAgeSeconds: visibleSample.map { max(0, now - $0.frame.received) },
            latencyP95MS: visibleSample != nil && (d?.count ?? 0) > 0 ? d?.p95MS : nil,
            modelMS: analysisSample?.inferenceMS,
            gpuMS: renderMeasurement.flatMap { $0.sequence == visibleSample?.frame.sequence ? $0.gpuMS : nil },
            fineCount: currentCoverage?.refined,
            totalContourCount: currentCoverage?.total,
            frameWidth: visibleSample.map { CVPixelBufferGetWidth($0.frame.pixels) },
            frameHeight: visibleSample.map { CVPixelBufferGetHeight($0.frame.pixels) },
            capturedSource: visibleSample != nil && cameraChoice != "auto"
                ? cameras.first { $0.uniqueID == cameraChoice }?.localizedName : nil
        )
    }
    private func refreshCameras() {
        lastDeviceScan = ProcessInfo.processInfo.systemUptime
        let found = Camera.devices()
        if found.map(\.uniqueID) != cameras.map(\.uniqueID) { cameras = found }
    }
}

struct MetalSurface: NSViewRepresentable {
    let controller: AppController
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.device)
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = true
        // A ProMotion display can notice fresh camera results sooner. The renderer
        // still encodes only when the packet or visible settings have changed.
        view.preferredFramesPerSecond = controller.renderer?.preferredPollRate ?? 60
        view.enableSetNeedsDisplay = false
        view.delegate = controller.renderer; return view
    }
    func updateNSView(_ view: MTKView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct PelagiVexNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        if CommandLine.arguments.dropFirst().first == "--camo-live-benchmark" { CamoLiveBenchmark.runAndExit() }
        if CommandLine.arguments.dropFirst().first == "--object-reconstruct" { ObjectReconstructionCommand.runAndExit() }
        if CommandLine.arguments.dropFirst().first == "--contour-benchmark" { ContourBenchmark.runAndExit() }
        if let command = CommandLine.arguments.dropFirst().first,
           command == "--pair-trace" || command == "--pair-replay" || command == "--tracking-replay" {
            PairTraceCommand.runAndExit()
        }
    }
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1360, height: 880).windowStyle(.hiddenTitleBar) }
}
#else
import Foundation
@main struct UnsupportedPlatform {
    static func main() { print("PelagiVex Native requires macOS 14+. Portable core tests are available with swift test.") }
}
#endif
