#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import CoreML
import MetalKit
import VisionCore

final class AppController: ObservableObject {
    @Published var status = "就绪。摄像头只会在点击启动后开启。"
    @Published var modelStatus = "未安装模型：可预览摄像头，不会生成虚假识别结果。"
    @Published var error = ""
    @Published var running = false
    @Published var loading = false
    @Published var mirror = false
    @Published var compute = "all"
    @Published var metrics = "尚无实测数据"
    @Published var objects: [(Int,String,Float)] = []
    let pipeline = Pipeline()
    let camera = Camera()
    let device = MTLCreateSystemDefaultDevice()
    var renderer: Renderer?
    private var timer: Timer?
    private var generation = 0
    private var modelFolder: URL?
    private var ready = false
    private var permissionPending = false

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
            self?.error = "推理已停止：\(text)"; self?.modelStatus = "模型异常，仅显示预览。请停止并重新加载模型。"
        } }
        renderer?.onError = { [weak self] text in DispatchQueue.main.async { self?.error = text } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        if let root = Bundle.main.resourceURL?.appendingPathComponent("Model"),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("model.json").path) { load(root) }
    }
    func chooseModel() {
        let dialog = NSOpenPanel(); dialog.canChooseFiles = false; dialog.canChooseDirectories = true
        dialog.title = "选择包含 model.json 和 UniversalSeg.mlpackage 的模型文件夹"
        if dialog.runModal() == .OK, let url = dialog.url { load(url) }
    }
    func reload() { if let modelFolder { load(modelFolder) } }
    private func load(_ folder: URL) {
        guard !running, !loading, let device else { return }
        loading = true; error = ""; status = "正在编译／加载 Core ML 模型…"
        let units: MLComputeUnits
        switch compute {
        case "cpu": units = .cpuOnly
        case "gpu": units = .cpuAndGPU
        case "ane": units = .cpuAndNeuralEngine
        default: units = .all
        }
        pipeline.load(folder: folder, compute: units, device: device) { [weak self] result in
            DispatchQueue.main.async { guard let self else { return }; self.loading = false
                switch result {
                case .success(let count):
                    self.modelFolder = folder; self.ready = true
                    self.modelStatus = "实例分割模型已加载 · \(count) 类 · \(self.compute)"
                    self.status = "模型已就绪。点击启动摄像头。"
                case .failure(let error): self.error = error.localizedDescription; self.status = "模型加载失败。"
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
                guard granted else { self.stop(); self.error = "摄像头权限未获准。请在系统设置 → 隐私与安全性 → 摄像头中允许 PelagiVex。"; return }
                self.renderer?.displayMeter.reset(); self.pipeline.active.set(ticket); self.camera.start()
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
        pipeline.stop(); camera.stop(); renderer?.displayMeter.reset(); objects = []; metrics = "已停止"
    }
    private func refresh() {
        renderer?.mirrored = mirror
        guard running, !permissionPending else { return }
        let c = pipeline.captureMeter.read(), i = pipeline.inferenceMeter.read(), d = renderer?.displayMeter.read()
        let packet = pipeline.packets.get()
        objects = packet?.detections.map { ($0.trackID, packet!.names[$0.classID], $0.score) } ?? []
        let gpu = renderer?.measurements.get()?.gpuMS ?? 0
        metrics = String(format: "采集 %.1f FPS · 推理 %.1f FPS · 新画面 %.1f FPS\n预处理 %.1f ms · Core ML %.1f ms · 后处理 %.1f ms\nMetal %.1f ms · 回调→GPU完成 P95 %.1f ms", c.fps,i.fps,d?.fps ?? 0,
                         packet?.preprocessMS ?? 0,packet?.inferenceMS ?? 0,packet?.postprocessMS ?? 0,gpu,d?.p95MS ?? 0)
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
                    Text("本地实例分割 · 实验版 v0.1").foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.running ? "停止摄像头" : "启动摄像头") {
                    if controller.running { controller.stop() } else { controller.start() }
                }.buttonStyle(.borderedProminent).disabled(controller.loading || controller.renderer == nil)
            }
            HStack(alignment: .top, spacing: 18) {
                MetalSurface(controller: controller).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 14) {
                    Text("模型与计算资源").font(.headline)
                    Text(controller.modelStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Picker("允许使用", selection: $controller.compute) {
                        Text("CPU + GPU + ANE（自动）").tag("all")
                        Text("CPU + GPU").tag("gpu")
                        Text("CPU + ANE").tag("ane")
                        Text("仅 CPU（对照）").tag("cpu")
                    }.disabled(controller.running || controller.loading)
                        .onChange(of: controller.compute) { _ in controller.reload() }
                    Button(controller.loading ? "模型加载中…" : "选择模型文件夹") { controller.chooseModel() }
                        .disabled(controller.running || controller.loading)
                    Toggle("镜像显示（不改变推理输入）", isOn: $controller.mirror)
                    Divider()
                    Text("当前物体").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(controller.objects.enumerated()), id: \.offset) { _, item in
                                Text("#\(item.0)  \(item.1)  \(Int(item.2*100))%").font(.system(.callout, design: .monospaced))
                            }
                            if controller.objects.isEmpty { Text("暂无识别结果").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("轮廓对应已分析帧；不上传、不录音、不默认保存画面。\nID 仅用于短时追踪，不代表人物身份。").font(.caption).foregroundStyle(.secondary)
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
