#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import CoreML
import MetalKit
import VisionCore

final class AppController: ObservableObject {
    @Published var status = "Ready. Click Start Camera to begin."
    @Published var modelStatus = "YOLO11x-seg is not installed. Camera preview only."
    @Published var error = ""
    @Published var running = false
    @Published var loading = false
    @Published var mirror = false
    @Published var metrics = "No measurements yet"
    @Published var objects: [(Int,String,Float,SIMD4<Float>?,Double?)] = []
    @Published var distanceStatus = "Distance: waiting for an object"
    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraChoice = UserDefaults.standard.string(forKey: "cameraChoice") ?? "auto" {
        didSet { UserDefaults.standard.set(cameraChoice, forKey: "cameraChoice") }
    }
    let pipeline = Pipeline()
    let camera = Camera()
    let device = MTLCreateSystemDefaultDevice()
    var renderer: Renderer?
    private var timer: Timer?
    private var generation = 0
    private var permissionPending = false
    private var lastDeviceScan = 0.0

    init() {
        if let device {
            do { renderer = try Renderer(device: device, pipeline: pipeline) }
            catch { self.error = error.localizedDescription }
        } else { error = "Metal is not available on this Mac." }
        camera.onFrame = { [weak self] frame in self?.pipeline.submit(frame) }
        camera.onState = { [weak self] text in DispatchQueue.main.async {
            self?.status = text
            if text.hasPrefix("Camera error:") { self?.stop(); self?.error = text }
        } }
        pipeline.onError = { [weak self] text in DispatchQueue.main.async {
            self?.error = "Inference stopped: \(text)"; self?.modelStatus = "Model error. Restart the app to reload YOLO11x-seg."
        } }
        renderer?.onError = { [weak self] text in DispatchQueue.main.async { self?.error = text } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        refreshCameras()
        if let root = Bundle.main.resourceURL?.appendingPathComponent("Model"),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("model.json").path) { load(root) }
    }
    private func load(_ folder: URL) {
        guard !running, !loading, let device else { return }
        loading = true; error = ""; status = "Compiling and loading the Core ML model…"
        pipeline.load(folder: folder, compute: .all, device: device) { [weak self] result in
            DispatchQueue.main.async { guard let self else { return }; self.loading = false
                switch result {
                case .success(let count):
                    self.modelStatus = "YOLO11x-seg · \(count) classes · loaded"
                    self.status = "Model ready. Click Start Camera."
                case .failure(let error): self.error = error.localizedDescription; self.status = "Model loading failed."
                }
            }
        }
    }
    func start() {
        guard !running, !loading, renderer != nil else { return }
        generation += 1; let ticket = generation
        running = true; permissionPending = true
        func proceed(_ granted: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == ticket else { return }
                self.permissionPending = false
                guard granted else { self.stop(); self.error = "Camera access denied. Allow PelagiVex in System Settings → Privacy & Security → Camera."; return }
                self.renderer?.displayMeter.reset(); self.pipeline.active.set(ticket); self.camera.start(deviceID: self.cameraChoice)
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: proceed(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: proceed)
        default: proceed(false)
        }
    }
    func stop() {
        generation += 1; running = false; permissionPending = false
        pipeline.stop(); camera.stop(); renderer?.displayMeter.reset(); objects = []; metrics = "Stopped"
    }
    private func refresh() {
        if ProcessInfo.processInfo.systemUptime - lastDeviceScan > 2 { refreshCameras() }
        renderer?.mirrored = mirror
        guard running, !permissionPending else { return }
        let c = pipeline.captureMeter.read(), i = pipeline.inferenceMeter.read(), d = renderer?.displayMeter.read()
        let packet = pipeline.packets.get()
        let displayed = renderer?.displayedObjects.get()
        let colors = displayed?.1 ?? [:]
        let displayedPacket = displayed?.0
        let distance = pipeline.distance.result.get()
        let fresh = distance.map { ProcessInfo.processInfo.systemUptime - $0.received < 5 } ?? false
        distanceStatus = pipeline.distance.status.get() ?? "Distance: waiting for an object"
        objects = displayedPacket?.detections.map { ($0.trackID, displayedPacket!.names[$0.classID], $0.score, colors[$0.trackID], fresh ? distance?.values[$0.trackID] : nil) } ?? []
        let gpu = renderer?.measurements.get()?.gpuMS ?? 0
        metrics = String(format: "Capture %.1f FPS · Inference %.1f FPS · Display %.1f FPS\nPreprocess %.1f ms · Core ML %.1f ms · Postprocess %.1f ms\nMetal %.1f ms · Callback to GPU P95 %.1f ms", c.fps,i.fps,d?.fps ?? 0,
                         packet?.preprocessMS ?? 0,packet?.inferenceMS ?? 0,packet?.postprocessMS ?? 0,gpu,d?.p95MS ?? 0)
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
        view.preferredFramesPerSecond = 60; view.enableSetNeedsDisplay = false
        view.delegate = controller.renderer; return view
    }
    func updateNSView(_ view: MTKView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var controller = AppController()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("PELAGIVEX / NATIVE").font(.title2.bold())
                    Text("On-device instance segmentation · Preview v0.1").foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.running ? "Stop Camera" : "Start Camera") {
                    if controller.running { controller.stop() } else { controller.start() }
                }.buttonStyle(.borderedProminent).disabled(controller.loading || controller.renderer == nil)
            }
            HStack(alignment: .top, spacing: 18) {
                MetalSurface(controller: controller).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Model & Compute").font(.headline)
                    Text(controller.modelStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text("Compute: CPU, GPU & Neural Engine (automatic)").font(.caption)
                    Picker("Camera", selection: $controller.cameraChoice) {
                        Text("External camera (automatic)").tag("auto")
                        ForEach(controller.cameras, id: \.uniqueID) { camera in
                            Text(camera.localizedName).tag(camera.uniqueID)
                        }
                        if controller.cameraChoice != "auto" && !controller.cameras.contains(where: { $0.uniqueID == controller.cameraChoice }) {
                            Text("Selected camera unavailable").tag(controller.cameraChoice)
                        }
                    }.disabled(controller.running)
                    Toggle("Mirror display", isOn: $controller.mirror)
                    Divider()
                    Text("Detected Objects").font(.headline)
                    Text(controller.distanceStatus).font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(controller.objects.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    if let color = item.3 {
                                        Circle().fill(Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z))).frame(width: 14, height: 14)
                                    } else {
                                        Circle().fill(.gray).frame(width: 14, height: 14)
                                    }
                                    VStack(alignment: .leading) {
                                        Text("\(item.1)  \(Int(item.2*100))%")
                                        Text(item.4.map { String(format: "Approx. depth %.2f m", $0) } ?? "Depth unavailable").foregroundStyle(.secondary)
                                    }.font(.system(.callout, design: .monospaced))
                                }
                            }
                            if controller.objects.isEmpty { Text("No objects detected").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Masks match the analyzed frame. No uploads, audio recording, or saved frames by default.\nIDs are short-term tracks, not identities.").font(.caption).foregroundStyle(.secondary)
                }.frame(width: 270)
            }
            Text(controller.metrics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            if !controller.error.isEmpty { Text(controller.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(22).frame(minWidth: 1050,minHeight: 700).onDisappear { controller.stop() }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct PelagiVexNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { WindowGroup { ContentView() }.defaultSize(width: 1280,height: 820) }
}
#else
import Foundation
@main struct UnsupportedPlatform {
    static func main() { print("PelagiVex Native requires macOS 14+. Portable core tests are available with swift test.") }
}
#endif
