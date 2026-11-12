#if os(macOS)
import Combine
import CryptoKit
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers

struct ModelScanAnalysis: Codable, Sendable {
    static let singleViewCaptureMode = "singleViewPrediction"
    let recordedAt: Date
    let trackID: Int
    let annotations: [ModelFeatureAnnotation]
    let photosByGuideStep: [String: Int]
    let captureMode: String?

    init(recordedAt: Date, trackID: Int, annotations: [ModelFeatureAnnotation], photosByGuideStep: [String: Int],
         captureMode: String? = nil) {
        self.recordedAt = recordedAt
        self.trackID = trackID
        self.annotations = annotations
        self.photosByGuideStep = photosByGuideStep
        self.captureMode = captureMode
    }

    static func from(_ scan: TargetScanPresentation, at recordedAt: Date, counts: [GuidedOrbitStep: Int],
                     automatic: Bool = false, singleView: Bool = false) -> Self? {
        guard let target = scan.target else { return nil }
        var annotations = [
            ModelFeatureAnnotation(label: "识别类别", value: target.name),
            ModelFeatureAnnotation(label: "识别置信度", value: String(format: "%.1f%%", target.confidence * 100))
        ]
        for label in ["采样平均色", "画面尺寸", "轮廓填充", "估计深度"] {
            guard let metric = scan.evidence.first(where: { $0.label == label }), metric.value != "—" else { continue }
            switch label {
            case "画面尺寸": annotations.append(ModelFeatureAnnotation(label: "锁定帧尺寸", value: "\(metric.value) px"))
            case "估计深度": annotations.append(ModelFeatureAnnotation(label: "锁定帧深度 · 未标定", value: metric.value))
            default: annotations.append(ModelFeatureAnnotation(label: label, value: metric.value))
            }
        }
        let photos = Dictionary(uniqueKeysWithValues: GuidedOrbitStep.allCases.map { ($0.key, counts[$0, default: 0]) })
        let captureMode = singleView ? singleViewCaptureMode :
            (automatic ? "automaticVisualSampling; guide steps are suggestions, not measured angles" : nil)
        return Self(recordedAt: recordedAt, trackID: target.id, annotations: annotations,
                    photosByGuideStep: photos, captureMode: captureMode)
    }
}

@MainActor
final class ObjectReconstruction: ObservableObject {
    enum State: String { case idle, preparing, running, cancelling, saving, completed, cancelled, failed }

    enum Detail: String, CaseIterable, Identifiable, Sendable {
        case preview, reduced, medium
        var id: Self { self }

        fileprivate var realityKitDetail: PhotogrammetrySession.Request.Detail {
            switch self {
            case .preview: return .preview
            case .reduced: return .reduced
            case .medium: return .medium
            }
        }
    }

    static let minimumPhotoCount = 20
    let isSupported = PhotogrammetrySession.isSupported
    @Published private(set) var state = State.idle
    @Published private(set) var progress: Double?
    @Published private(set) var message = "请选择包含同一物体多视角照片的文件夹。相邻照片应有较多重叠。"
    @Published private(set) var outputURL: URL?
    @Published private(set) var provenanceURL: URL?
    @Published private(set) var linkedAnalysis: ModelScanAnalysis?

    var isBusy: Bool { state == .preparing || state == .running || state == .cancelling || state == .saving }
    var singleViewPrediction: Bool { linkedAnalysis?.captureMode == ModelScanAnalysis.singleViewCaptureMode }
    private static var jobActive = false
    private var worker: ObjectReconstructionWorker?
    private var task: Task<Void, Never>?
    private var analysisLoad: Task<Void, Never>?

    func start(inputFolder: URL, outputURL: URL, detail: Detail = .reduced, sequential: Bool = false,
               linkedAnalysis: ModelScanAnalysis? = nil) {
        guard !isBusy else { return }
        analysisLoad?.cancel()
        self.linkedAnalysis = nil
        progress = nil
        self.outputURL = nil
        provenanceURL = nil
        guard isSupported else {
            state = .failed
            message = "这台 Mac 不支持 RealityKit 物体重建。"
            return
        }
        guard !Self.jobActive else {
            state = .failed
            message = "PelagiVex 正在重建另一个物体。请等待完成或取消该任务。"
            return
        }
        let worker = ObjectReconstructionWorker(inputFolder: inputFolder.standardizedFileURL,
            outputURL: outputURL.standardizedFileURL, detail: detail, sequential: sequential,
            minimumPhotoCount: Self.minimumPhotoCount, linkedAnalysis: linkedAnalysis)
        self.worker = worker
        Self.jobActive = true
        state = .preparing
        message = "正在检查照片并准备重建…"
        task = Task { [weak self] in
            defer {
                Self.jobActive = false
                self?.worker = nil
                self?.task = nil
            }
            do {
                let completed = try await worker.run(
                    update: { [weak self] event in self?.receive(event) },
                    beginSaving: { [weak self] in self?.beginSaving() ?? false })
                guard let self else { return }
                self.linkedAnalysis = linkedAnalysis
                self.outputURL = completed.model
                self.provenanceURL = completed.provenance
                self.progress = 1
                self.state = .completed
                self.message = completed.message
            } catch is CancellationError {
                self?.state = .cancelled
                self?.progress = nil
                self?.message = "重建已取消。"
            } catch {
                self?.state = .failed
                self?.progress = nil
                self?.message = "重建失败。\(error.localizedDescription)"
            }
        }
    }

    func startSingleView(input: SingleViewInput, outputURL: URL, linkedAnalysis: ModelScanAnalysis) {
        guard !isBusy else { return }
        guard !Self.jobActive else {
            state = .failed
            message = "PelagiVex 正在重建另一个物体。请等待完成或取消该任务。"
            return
        }
        analysisLoad?.cancel()
        self.linkedAnalysis = nil
        progress = nil
        self.outputURL = nil
        provenanceURL = nil
        Self.jobActive = true
        state = .running
        message = "正在预测单视角体积…"
        task = Task { [weak self] in
            defer { Self.jobActive = false; self?.task = nil }
            do {
                let record = try await SingleViewPublication.run(input: input, outputURL: outputURL, analysis: linkedAnalysis,
                    beginSaving: { [weak self] in self?.beginSaving() ?? false })
                guard let self else { return }
                self.linkedAnalysis = linkedAnalysis
                self.outputURL = outputURL
                self.provenanceURL = record
                self.progress = 1
                self.state = .completed
                self.message = "已保存单视角体积预测。"
            } catch is CancellationError {
                self?.state = .cancelled
                self?.message = "重建已取消。"
            } catch {
                self?.state = .failed
                self?.message = "单视角建模失败。\(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        guard state == .preparing || state == .running else { return }
        let preparing = state == .preparing
        state = .cancelling
        message = "正在取消重建…"
        if preparing || worker == nil { task?.cancel() }
        if let worker { Task { await worker.cancel() } }
    }

    func openExistingModel(_ url: URL) {
        guard !isBusy else { return }
        analysisLoad?.cancel()
        linkedAnalysis = nil
        progress = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try validatedUSDZSize(url)
            let record = url.appendingPathExtension("capture.json")
            outputURL = url
            provenanceURL = FileManager.default.fileExists(atPath: record.path) ? record : nil
            state = .idle
            message = "已打开已有模型。"
            if provenanceURL != nil {
                analysisLoad = Task { [weak self] in
                    let analysis = await Task.detached(priority: .utility) {
                        ObjectReconstructionWorker.linkedAnalysis(for: url, record: record)
                    }.value
                    guard !Task.isCancelled, self?.outputURL == url else { return }
                    self?.linkedAnalysis = analysis
                }
            }
        } catch {
            outputURL = nil
            provenanceURL = nil
            state = .failed
            message = "无法打开模型。\(error.localizedDescription)"
        }
    }

    /// This main-actor transition is the commit point. Earlier cancellation discards the staged model.
    private func beginSaving() -> Bool {
        guard state == .running else { return false }
        state = .saving
        message = "正在保存模型和采集记录…"
        return true
    }

    private func receive(_ event: ObjectReconstructionWorker.Event) {
        guard state != .cancelling else { return }
        switch event {
        case .starting(let photos):
            state = .running
            message = "正在向 RealityKit 导入 \(photos) 张照片…"
        case .progress(let value):
            if value.isFinite { progress = max(progress ?? 0, min(1, max(0, value))) }
        case .message(let text):
            message = text
        }
    }
}

private enum SingleViewPublication {
    struct Record: Encodable {
        let outputBytes: Int
        let outputSHA256: String
        let linkedAnalysis: ModelScanAnalysis
        let prediction: SingleViewPrediction.Report
    }

    static func run(input: SingleViewInput, outputURL: URL, analysis: ModelScanAnalysis,
                    beginSaving: @MainActor @Sendable () -> Bool) async throws -> URL {
        let files = FileManager.default
        let stage = outputURL.deletingLastPathComponent().appendingPathComponent(".prediction-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: stage) }
        let model = stage.appendingPathComponent(outputURL.lastPathComponent)
        let report = try await SingleViewPrediction.write(input, to: model)
        let bytes = try validatedUSDZSize(model)
        let digest = try ObjectReconstructionWorker.digest(model)
        let record = Record(outputBytes: bytes, outputSHA256: digest, linkedAnalysis: analysis, prediction: report)
        let stagedRecord = model.appendingPathExtension("capture.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: stagedRecord)
        guard await beginSaving() else { throw CancellationError() }
        let destination = outputURL.appendingPathExtension("capture.json")
        try files.moveItem(at: stagedRecord, to: destination)
        do { try files.moveItem(at: model, to: outputURL) }
        catch {
            try? files.removeItem(at: destination)
            throw error
        }
        return destination
    }
}

private struct ReconstructionFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
    init(_ text: String) { self.text = text }
}

private func validatedUSDZSize(_ file: URL) throws -> Int {
    guard file.isFileURL, file.pathExtension.lowercased() == "usdz",
          FileManager.default.fileExists(atPath: file.path) else {
        throw ReconstructionFailure("请选择存在的本地 .usdz 文件。")
    }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 4 else {
        throw ReconstructionFailure("文件为空或不是有效的 USDZ 文件。")
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    guard try handle.read(upToCount: 4) == Data([0x50, 0x4B, 0x03, 0x04]) else {
        throw ReconstructionFailure("文件没有有效的 USDZ 存档签名。")
    }
    return size
}

/// Own the RealityKit session off the main actor and keep consuming events until it stops.
private actor ObjectReconstructionWorker {
    enum Event: Sendable { case starting(Int), progress(Double), message(String) }

    struct Completed: Sendable {
        let model: URL
        let provenance: URL
        let message: String
    }

    private struct Photo: Encodable {
        let filename: String
        let bytes: Int
        let sha256: String
    }

    private struct Provenance: Encodable {
        let engine = "Apple RealityKit PhotogrammetrySession"
        let inputFolder: String
        let photos: [Photo]
        let detail: String
        let sampleOrdering: String
        let featureSensitivity = "normal"
        let objectMaskingEnabled = true
        let outputFile: String
        let outputBytes: Int
        let outputSHA256: String
        let startedAt: Date
        let elapsedSeconds: Double
        let processingSeconds: Double
        let operatingSystem: String
        let inputWarnings: [String]
        let linkedAnalysis: ModelScanAnalysis?
    }

    private struct SavedAnalysis: Decodable {
        let outputBytes: Int
        let outputSHA256: String
        let linkedAnalysis: ModelScanAnalysis?
    }

    private let inputFolder: URL
    private let outputURL: URL
    private let detail: ObjectReconstruction.Detail
    private let sequential: Bool
    private let minimumPhotoCount: Int
    private let linkedAnalysis: ModelScanAnalysis?
    private var session: PhotogrammetrySession?
    private var cancellationRequested = false

    init(inputFolder: URL, outputURL: URL, detail: ObjectReconstruction.Detail,
         sequential: Bool, minimumPhotoCount: Int, linkedAnalysis: ModelScanAnalysis?) {
        self.inputFolder = inputFolder
        self.outputURL = outputURL
        self.detail = detail
        self.sequential = sequential
        self.minimumPhotoCount = minimumPhotoCount
        self.linkedAnalysis = linkedAnalysis
    }

    static func linkedAnalysis(for model: URL, record: URL) -> ModelScanAnalysis? {
        let access = model.startAccessingSecurityScopedResource()
        defer { if access { model.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let properties = try? record.resourceValues(forKeys: keys), properties.isRegularFile == true,
              let size = properties.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: record) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(SavedAnalysis.self, from: data), let analysis = saved.linkedAnalysis,
              !analysis.annotations.isEmpty, analysis.annotations.count <= 12,
              analysis.annotations.allSatisfy({ $0.label.count <= 64 && $0.value.count <= 160 }),
              (try? validatedUSDZSize(model)) == saved.outputBytes,
              (try? digest(model)) == saved.outputSHA256 else { return nil }
        return analysis
    }

    func cancel() {
        cancellationRequested = true
        session?.cancel()
    }

    func run(update: @MainActor @Sendable (Event) -> Void,
             beginSaving: @MainActor @Sendable () -> Bool) async throws -> Completed {
        let startedAt = Date()
        let started = ProcessInfo.processInfo.systemUptime
        let outputFolder = outputURL.deletingLastPathComponent()
        let inputAccess = inputFolder.startAccessingSecurityScopedResource()
        let outputAccess = outputFolder.startAccessingSecurityScopedResource()
        defer {
            if inputAccess { inputFolder.stopAccessingSecurityScopedResource() }
            if outputAccess { outputFolder.stopAccessingSecurityScopedResource() }
            session = nil
        }
        guard inputFolder.isFileURL, outputURL.isFileURL, outputURL.pathExtension.lowercased() == "usdz" else {
            throw ReconstructionFailure("请选择本地照片文件夹和 .usdz 输出文件。")
        }
        let files = FileManager.default
        let provenanceURL = outputURL.appendingPathExtension("capture.json")
        guard !files.fileExists(atPath: outputURL.path), !files.fileExists(atPath: provenanceURL.path) else {
            throw ReconstructionFailure("模型或采集记录已存在。请选择新的文件名。")
        }
        let photos = try inspectPhotos()
        try Task.checkCancellation()
        await update(.starting(photos.count))
        try Task.checkCancellation()
        if cancellationRequested { throw CancellationError() }

        try files.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let staging = outputFolder.appendingPathComponent(".pelagivex-capture-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let stagedModel = staging.appendingPathComponent("Object.usdz")
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = sequential ? .sequential : .unordered
        configuration.featureSensitivity = .normal
        configuration.isObjectMaskingEnabled = true
        let session = try PhotogrammetrySession(input: inputFolder, configuration: configuration)
        self.session = session
        let request = PhotogrammetrySession.Request.modelFile(url: stagedModel, detail: detail.realityKitDetail)
        let outputs = session.outputs
        let processingStarted = ProcessInfo.processInfo.systemUptime
        try session.process(requests: [request])
        var result: URL?
        var requestError: Error?
        var warnings: [String] = []

        for try await event in outputs {
            switch event {
            case .inputComplete:
                await update(.message("照片已加载，正在对齐视角…"))
            case .requestProgress(_, let fraction):
                await update(.progress(fraction))
            case .requestProgressInfo(_, let info):
                if let stage = info.processingStage, let text = Self.stageMessage(stage) {
                    await update(.message(text))
                }
            case .invalidSample(let id, let reason):
                warnings.append("Invalid photo \(id): \(reason)")
            case .skippedSample(let id):
                warnings.append("Skipped photo \(id).")
            case .automaticDownsampling:
                warnings.append("RealityKit reduced input resolution to fit available resources.")
            case .stitchingIncomplete:
                warnings.append("RealityKit could not fully stitch all viewpoints.")
            case .requestComplete(let completedRequest, .modelFile(let url)) where completedRequest == request:
                result = url
            case .requestComplete:
                break
            case .requestError(_, let error):
                requestError = error
                if session.isProcessing { session.cancel() }
                else { throw error }
            case .processingCancelled:
                if let requestError { throw requestError }
                throw CancellationError()
            case .processingComplete:
                if let requestError { throw requestError }
                if cancellationRequested { throw CancellationError() }
                guard let result, result.resolvingSymlinksInPath() == stagedModel.resolvingSymlinksInPath() else {
                    throw ReconstructionFailure("RealityKit 已结束，但未返回指定的 3D 模型。")
                }
                let processingSeconds = ProcessInfo.processInfo.systemUptime - processingStarted
                await update(.message("正在验证 USDZ 模型…"))
                let bytes = try validatedUSDZSize(stagedModel)
                let outputDigest = try Self.digest(stagedModel)
                guard await beginSaving() else { throw CancellationError() }
                let record = Provenance(inputFolder: inputFolder.path, photos: photos, detail: detail.rawValue,
                    sampleOrdering: sequential ? "sequential" : "unordered", outputFile: outputURL.lastPathComponent,
                    outputBytes: bytes, outputSHA256: outputDigest, startedAt: startedAt,
                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, processingSeconds: processingSeconds,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, inputWarnings: warnings,
                    linkedAnalysis: linkedAnalysis)
                try publish(stagedModel: stagedModel, provenance: record, destination: provenanceURL)
                let note = warnings.isEmpty ? "" : "采集记录包含 \(warnings.count) 条输入提示。"
                return Completed(model: outputURL, provenance: provenanceURL, message: "已保存 3D 模型。\(note)")
            @unknown default:
                break
            }
        }
        if let requestError { throw requestError }
        if cancellationRequested { throw CancellationError() }
        throw ReconstructionFailure("RealityKit 已结束，但未报告重建完成。")
    }

    private func inspectPhotos() throws -> [Photo] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard try inputFolder.resourceValues(forKeys: keys).isDirectory == true else {
            throw ReconstructionFailure("请选择照片文件夹。")
        }
        let entries = try FileManager.default.contentsOfDirectory(at: inputFolder,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]).sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        var photos: [Photo] = []
        for entry in entries {
            try Task.checkCancellation()
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                  UTType(filenameExtension: entry.pathExtension)?.conforms(to: .image) == true,
                  let source = CGImageSourceCreateWithURL(entry as CFURL, nil), CGImageSourceGetCount(source) > 0 else { continue }
            photos.append(Photo(filename: entry.lastPathComponent, bytes: size, sha256: try Self.digest(entry)))
        }
        guard Set(photos.map(\.sha256)).count >= minimumPhotoCount else {
            throw ReconstructionFailure("请提供至少 \(minimumPhotoCount) 张不同视角、可读取的照片。")
        }
        let maximum = PhotogrammetrySession.limits.maximumNumberOfInputImages
        guard photos.count <= maximum else {
            throw ReconstructionFailure("这台 Mac 每次最多可处理 \(maximum) 张重建照片。")
        }
        return photos
    }

    private func publish(stagedModel: URL, provenance: Provenance, destination: URL) throws {
        let stagedRecord = stagedModel.appendingPathExtension("capture.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(provenance).write(to: stagedRecord, options: .atomic)
        let files = FileManager.default
        try files.moveItem(at: stagedRecord, to: destination)
        do { try files.moveItem(at: stagedModel, to: outputURL) }
        catch {
            try? files.removeItem(at: destination)
            throw error
        }
    }

    fileprivate static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stageMessage(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String? {
        switch stage {
        case .preProcessing: return "正在准备照片…"
        case .imageAlignment: return "正在对齐视角…"
        case .pointCloudGeneration: return "正在估算三维点云…"
        case .meshGeneration: return "正在生成三维网格…"
        case .textureMapping: return "正在映射照片纹理…"
        case .optimization: return "正在优化带纹理的模型…"
        @unknown default: return nil
        }
    }
}

enum ObjectReconstructionCommand {
    static func runAndExit() -> Never {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard (2...3).contains(args.count),
              let detail = ObjectReconstruction.Detail(rawValue: args.count == 3 ? args[2] : "reduced") else {
            fputs("用法  --object-reconstruct <照片文件夹> <输出.usdz> [preview|reduced|medium]\n", stderr)
            exit(EXIT_FAILURE)
        }
        Task { @MainActor in
            let reconstruction = ObjectReconstruction()
            reconstruction.start(inputFolder: URL(fileURLWithPath: args[0], isDirectory: true),
                outputURL: URL(fileURLWithPath: args[1]), detail: detail)
            var lastLine = ""
            while reconstruction.isBusy {
                let percent = reconstruction.progress.map { String(format: "%.0f%% ", $0 * 100) } ?? ""
                let line = percent + reconstruction.message
                if line != lastLine { print(line); fflush(stdout); lastLine = line }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard reconstruction.state == .completed, let output = reconstruction.outputURL,
                  let record = reconstruction.provenanceURL else {
                fputs(reconstruction.message + "\n", stderr)
                exit(EXIT_FAILURE)
            }
            print(output.path)
            print(record.path)
            exit(EXIT_SUCCESS)
        }
        RunLoop.main.run()
        fatalError("The reconstruction command run loop exited unexpectedly.")
    }
}
#endif
