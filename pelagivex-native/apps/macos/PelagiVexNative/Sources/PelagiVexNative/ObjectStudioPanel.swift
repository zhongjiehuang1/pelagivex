#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VisionCore

struct ObjectStudioPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var capture: ObjectScanCapture
    @ObservedObject var reconstruction: ObjectReconstruction
    @ObservedObject var guide: GuidedOrbitSession
    @ObservedObject var automatic: AutoOrbitSession
    @Binding var showingModel: Bool
    @State private var actionError: String?
    @State private var exportNotice: String?

    private var busy: Bool { capture.isFinishing || reconstruction.isBusy }
    private var canUseFilePicker: Bool { !capture.isCapturing && !busy && guide.target == nil }
    private var minimumPhotos: Int { ObjectReconstruction.minimumPhotoCount }
    private var canStartCapture: Bool {
        guard controller.running, let age = controller.telemetry.frameAgeSeconds, age.isFinite else { return false }
        return age >= 0 && age <= (controller.recognitionMode == .fast ? 0.75 : 5)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let phase = automatic.phase { automaticPanel(phase) }
                else {
                    if showingModel { modelPanel }
                    if let target = guide.target?.target { guidedPanel(target: target) }
                    else { capturePanel }
                    reconstructionPanel
                    if !showingModel { modelPanel }
                }
                if let actionError {
                    Text(actionError).font(.system(size: 11)).foregroundStyle(ConsoleStyle.amber)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(12)
        }
        .onChange(of: reconstruction.outputURL) { _, url in
            if url != nil, reconstruction.state == .completed { showingModel = true }
        }
        .onChange(of: capture.guidedCounts) { _, _ in guide.synchronize(capture) }
        .onChange(of: capture.isCapturing) { _, _ in guide.synchronize(capture) }
    }

    private func automaticPanel(_ phase: AutoOrbitPanel.Phase) -> some View {
        let canFinish = automatic.canFinish(capture)
        let build = { automatic.reconstruct(controller: controller, reconstruction: reconstruction) }
        let working = reconstruction.state == .preparing || reconstruction.state == .running
        return AutoOrbitPanel(phase: phase, targetName: automatic.targetName,
            savedCount: automatic.savedCount(capture), goalCount: AutoOrbitPolicy.automaticPhotos,
            guidance: phase == .reconstructing && reconstruction.isBusy ? reconstruction.message : automatic.guidance,
            quality: phase == .capturing ? (capture.unchangedSamples > 0 && automatic.step == .front &&
                automatic.savedCount(capture) <= 2 ? "镜头保持稳定，正在确认视角。" : capture.automaticQuality) : nil,
            reconstructionProgress: phase == .reconstructing ? reconstruction.progress : nil,
            onPause: { automatic.pause(capture) }, onResume: { automatic.resume(controller) },
            onFinishEarly: (phase == .capturing || phase == .paused) && canFinish ? build : nil,
            onCancel: { automatic.cancel(controller: controller, reconstruction: reconstruction) },
            onRetry: phase == .failed && canFinish ? build : nil,
            canCancel: phase != .reconstructing || working || capture.isFinishing)
    }

    private func guidedPanel(target: ObjectRow) -> some View {
        let stepFull = capture.guidedCounts[guide.step, default: 0] >= ObjectScanCapture.maximumGuidedPhotosPerStep
        return GuidedOrbitPanel(targetName: target.name, step: guide.step, counts: capture.guidedCounts,
            isCapturing: guide.isRecording, isFinishing: capture.isFinishing,
            canCapture: canStartCapture && capture.isCapturing && !stepFull,
            minimumPhotos: minimumPhotos, message: guidedMessage(stepFull: stepFull),
            onToggleCapture: {
                if guide.isRecording || canStartCapture { guide.toggleCapture(capture) }
            }, onAdvance: { guide.advance(capture) }, onExit: {
                guard !busy else { return }
                guide.pause(capture)
                capture.stop()
                guide.reset()
            }, onReconstruct: reconstruction.isSupported && guide.ready(capture) ? reconstructCapture : nil,
            isReconstructing: reconstruction.isBusy)
    }

    private func guidedMessage(stepFull: Bool) -> String {
        if reconstruction.isBusy { return reconstruction.message }
        if !capture.isCapturing { return capture.message }
        if stepFull { return "本段已拍满。可以确认并继续。" }
        if !canStartCapture { return "等待新画面后可拍摄。" }
        return guide.advisory(rows: controller.objects)
    }

    private var capturePanel: some View {
        ConsolePanel(title: "绕拍采集", kicker: "OBJECT STUDIO / 01") {
            HStack {
                Text("已保存照片").font(.system(size: 11)).foregroundStyle(ConsoleStyle.muted)
                Spacer()
                Text("\(capture.count)").font(ConsoleStyle.mono(size: 25, weight: .light))
                    .foregroundStyle(ConsoleStyle.cyan).monospacedDigit()
            }.accessibilityElement(children: .combine)
            note("保持物体静止，缓慢绕拍并补充高低角度。相邻画面应保留共同特征。")
            HStack(spacing: 7) {
                Button(controller.focusSelecting ? "取消框选" : "框选目标") {
                    showingModel = false
                    controller.focusSelecting.toggle()
                }.buttonStyle(ConsoleButtonStyle())
                    .disabled(!canStartCapture || capture.isCapturing || busy)
                if controller.focusRegion != nil {
                    Button("清除区域") { controller.setFocus(nil) }
                        .buttonStyle(ConsoleButtonStyle()).disabled(capture.isCapturing || busy)
                }
            }
            note(controller.focusRegion == nil
                 ? "当前保存完整画面。每秒最多保存一张原始照片。"
                 : "区域筛选目标并裁剪扫描照片。绕拍时保持整个物体在框内。")
            Button(capture.isCapturing ? "停止保存" : "开始新扫描") {
                actionError = nil
                if capture.isCapturing {
                    capture.stop()
                } else {
                    guard canStartCapture else { return }
                    showingModel = false
                    controller.focusSelecting = false
                    let imageSize: CGSize?
                    if let width = controller.telemetry.frameWidth, let height = controller.telemetry.frameHeight {
                        imageSize = CGSize(width: width, height: height)
                    } else {
                        imageSize = nil
                    }
                    capture.start(region: controller.focusRegion,
                                  source: controller.telemetry.capturedSource ?? controller.selectedCameraName,
                                  imageSize: imageSize)
                }
            }.buttonStyle(ConsoleButtonStyle(primary: true, destructive: capture.isCapturing))
                .disabled(busy || (!capture.isCapturing && !canStartCapture))
            if capture.isFinishing {
                note("正在写入最后一张照片…")
            } else if !controller.running && capture.folderURL == nil {
                note("先启动摄像头，再开始扫描。")
            } else {
                note(capture.message)
            }
            if controller.running && !canStartCapture && !capture.isCapturing && !busy {
                note("等待新画面后可开始扫描。")
            }
            if let folder = capture.folderURL {
                Button("查看照片目录") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(ConsoleButtonStyle())
            }
        }
    }

    private var reconstructionPanel: some View {
        ConsolePanel(title: "多视角重建", kicker: "PHOTOGRAMMETRY / 02") {
            ConsoleTag(phaseLabel, color: phaseColor)
            if reconstruction.isBusy {
                if let progress = reconstruction.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("三维重建进度")
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel(phaseLabel)
                }
                Button(reconstruction.state == .cancelling ? "正在取消" : "取消重建", action: reconstruction.cancel)
                    .buttonStyle(ConsoleButtonStyle(destructive: true))
                    .disabled(reconstruction.state == .cancelling || reconstruction.state == .saving)
            }
            if reconstruction.state != .idle { note(reconstruction.message) }
            if reconstruction.isSupported {
                note("至少 \(minimumPhotos) 张照片可提交。模型质量取决于视角覆盖、重叠和画面清晰度。")
                note("重建范围取决于照片覆盖。缺失的背面或底面需补拍。模型未做尺寸标定。")
            } else {
                note("此 Mac 当前不支持 RealityKit 照片重建。仍可打开已有 USDZ。")
            }
            if guide.target == nil {
                Button(capture.isCapturing ? "停止并重建" : "重建已拍照片", action: reconstructCapture)
                    .buttonStyle(ConsoleButtonStyle(primary: true))
                    .disabled(busy || !reconstruction.isSupported || capture.count < minimumPhotos || capture.folderURL == nil)
            }
            Button("导入照片文件夹…", action: importPhotos)
                .buttonStyle(ConsoleButtonStyle()).disabled(!canUseFilePicker || !reconstruction.isSupported)
        }
    }

    private var modelPanel: some View {
        ConsolePanel(title: "查看 USDZ", kicker: "MODEL VIEWER / 03") {
            if let model = reconstruction.outputURL {
                Text(model.lastPathComponent).font(ConsoleStyle.mono(size: 10, weight: .semibold))
                    .lineLimit(1).help(model.path)
                Button(showingModel ? "返回视野" : "查看三维模型") {
                    if !showingModel && controller.running { controller.stop() }
                    showingModel.toggle()
                }.buttonStyle(ConsoleButtonStyle(primary: true)).disabled(capture.isCapturing || busy)
                HStack(spacing: 7) {
                    Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([model]) }
                        .buttonStyle(ConsoleButtonStyle())
                    Button("用系统打开") { NSWorkspace.shared.open(model) }
                        .buttonStyle(ConsoleButtonStyle())
                }
                if let provenance = reconstruction.provenanceURL {
                    Button("查看重建记录") { NSWorkspace.shared.activateFileViewerSelecting([provenance]) }
                        .buttonStyle(ConsoleButtonStyle())
                }
                Button("导出 USDZ…") { exportModel(model) }
                    .buttonStyle(ConsoleButtonStyle())
                if let exportNotice { note(exportNotice) }
            } else {
                note("重建完成后，可拖动模型查看不同角度。")
            }
            Button("打开已有 USDZ…", action: openModel)
                .buttonStyle(ConsoleButtonStyle()).disabled(!canUseFilePicker)
        }
    }

    private var phaseLabel: String {
        if capture.isFinishing { return "照片写入中" }
        switch reconstruction.state {
        case .idle: return "就绪"
        case .preparing: return "检查照片"
        case .running: return "重建中"
        case .saving: return "保存模型"
        case .cancelling: return "正在取消"
        case .completed: return "重建完成"
        case .cancelled: return "已取消"
        case .failed: return "重建或打开失败"
        }
    }

    private var phaseColor: Color {
        if reconstruction.state == .failed { return ConsoleStyle.red }
        return busy || reconstruction.state == .cancelled ? ConsoleStyle.amber : ConsoleStyle.cyan
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    private func reconstructCapture() {
        guard !busy, reconstruction.isSupported, capture.count >= minimumPhotos, capture.folderURL != nil else { return }
        guard guide.target == nil || guide.ready(capture) else { return }
        actionError = nil
        guide.pause(capture)
        capture.finish { folder in
            guard let folder else {
                actionError = "找不到已保存的照片目录。"
                return
            }
            controller.stop()
            showingModel = false
            let analysis = makeLinkedAnalysis()
            reconstruction.start(inputFolder: folder,
                outputURL: folder.deletingLastPathComponent().appendingPathComponent("model-\(UUID().uuidString.prefix(8)).usdz"),
                detail: .reduced, sequential: true, linkedAnalysis: analysis)
        }
    }

    private func makeLinkedAnalysis() -> ModelScanAnalysis? {
        guard let scan = guide.target, let recordedAt = guide.recordedAt else { return nil }
        return ModelScanAnalysis.from(scan, at: recordedAt, counts: capture.guidedCounts)
    }

    private func importPhotos() {
        guard canUseFilePicker, reconstruction.isSupported else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择照片文件夹"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        actionError = nil
        do {
            let files = FileManager.default
            let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
            let run = support.appendingPathComponent("PelagiVex/Scans", isDirectory: true)
                .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: run, withIntermediateDirectories: true)
            controller.stop()
            showingModel = false
            reconstruction.start(inputFolder: source, outputURL: run.appendingPathComponent("model.usdz"),
                                 detail: .reduced, sequential: false)
        } catch { actionError = "无法创建重建目录。\(error.localizedDescription)" }
    }

    private func openModel() {
        guard canUseFilePicker else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.usdz]
        panel.prompt = "打开模型"
        guard panel.runModal() == .OK, let model = panel.url else { return }
        actionError = nil
        exportNotice = nil
        reconstruction.openExistingModel(model)
        if reconstruction.outputURL?.standardizedFileURL == model.standardizedFileURL {
            if controller.running { controller.stop() }
            showingModel = true
        } else {
            showingModel = false
        }
    }

    private func exportModel(_ model: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.usdz]
        panel.nameFieldStringValue = model.lastPathComponent
        panel.prompt = "导出"
        let record = reconstruction.provenanceURL
        let includeRecord = NSButton(checkboxWithTitle: reconstruction.linkedAnalysis == nil ? "同时导出重建记录" : "同时导出重建记录和特征标注", target: nil, action: nil)
        if reconstruction.linkedAnalysis != nil { includeRecord.state = .on }
        if record != nil {
            includeRecord.sizeToFit()
            panel.accessoryView = includeRecord
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        actionError = nil
        exportNotice = nil
        guard destination.resolvingSymlinksInPath() != model.resolvingSymlinksInPath() else {
            exportNotice = "模型已在所选位置。"
            return
        }
        do {
            try copyExport(model, to: destination, record: includeRecord.state == .on ? record : nil)
            exportNotice = "已导出 \(destination.lastPathComponent)。"
        } catch { actionError = "导出失败。\(error.localizedDescription)" }
    }

    private func copyExport(_ model: URL, to destination: URL, record: URL?) throws {
        let files = FileManager.default
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".pelagivex-export-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        let stagedModel = stage.appendingPathComponent("model.usdz")
        try files.copyItem(at: model, to: stagedModel)

        let recordDestination = destination.appendingPathExtension("capture.json")
        if let record {
            let stagedRecord = stage.appendingPathComponent("capture.json")
            try files.copyItem(at: record, to: stagedRecord)
            try files.moveItem(at: stagedRecord, to: recordDestination)
        }
        do {
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: stagedModel)
            } else {
                try files.moveItem(at: stagedModel, to: destination)
            }
        } catch {
            if record != nil { try? files.removeItem(at: recordDestination) }
            throw error
        }
    }
}
#endif
