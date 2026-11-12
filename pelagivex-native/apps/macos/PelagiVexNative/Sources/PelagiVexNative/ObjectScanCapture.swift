#if os(macOS)
import Foundation
import Combine
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VisionCore

/// Captures original, unmirrored camera frames, never HUD or segmentation overlays.
/// One queued encode at a time prevents the capture callback from accumulating work.
final class ObjectScanCapture: ObservableObject {
    static let maximumGuidedPhotosPerStep = 12
    @Published private(set) var isCapturing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var count = 0
    @Published private(set) var guidedCounts: [GuidedOrbitStep: Int] = [:]
    @Published private(set) var folderURL: URL?
    @Published private(set) var message = "保持物体静止，缓慢绕拍。每秒保存一张原始画面。"
    @Published private(set) var automaticQuality: String?
    @Published private(set) var unchangedSamples = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "pelagivex.object-capture", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var active = false
    private var busy = false
    private var lastTime = -Double.infinity
    private var token = UUID()
    private var guided = false
    private var automatic = false
    private var guidedStep: GuidedOrbitStep?
    private var guidedStepStartedAt = Double.infinity
    private var recordedSteps: [GuidedOrbitStep: Int] = [:]
    // Access below is confined to queue, except initialization after queue drains.
    private var folder: URL?
    private var region: FocusRegion?
    private var source = ""
    private var expectedImageSize: CGSize?
    private var records: [[String: Any]] = []
    private var automaticGate = AutoOrbitFrameGate()
    private var repeatEpoch = Double.infinity
    private var repeats = 0

    func start(region: FocusRegion?, source: String, imageSize: CGSize? = nil, guided: Bool = false, automatic: Bool = false) {
        guard !isCapturing, !isFinishing else { return }
        stop()
        guard !isFinishing else { return }
        let ticket = UUID()
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("PelagiVex/Scans/\(Int(Date().timeIntervalSince1970))-\(ticket.uuidString.prefix(8))")
            let input = root.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            queue.sync {
                self.folder = input; self.region = guided || automatic ? nil : region; self.source = source
                records = []; self.expectedImageSize = imageSize
                automaticGate.reset()
                repeatEpoch = .infinity
                repeats = 0
            }
            lock.lock()
            token = ticket; lastTime = -.infinity; busy = false; active = true
            self.guided = guided || automatic; self.automatic = automatic
            guidedStep = nil; guidedStepStartedAt = .infinity; recordedSteps = [:]
            lock.unlock()
            count = 0; folderURL = input; isCapturing = true
            guidedCounts = [:]
            automaticQuality = nil
            unchangedSamples = 0
            message = guided ? "准备拍摄第一段。" : "绕拍中 · 每秒一张 · 最多 180 张。物体始终保持在区域内。"
        } catch { message = "无法创建扫描目录：\(error.localizedDescription)" }
    }
    func setGuidedStep(_ step: GuidedOrbitStep?) {
        lock.lock()
        guard active, guided, step != guidedStep,
              step.map({ recordedSteps[$0, default: 0] < Self.maximumGuidedPhotosPerStep }) ?? true else {
            lock.unlock()
            return
        }
        guidedStep = step
        guidedStepStartedAt = step == nil ? .infinity : ProcessInfo.processInfo.systemUptime
        lock.unlock()
        unchangedSamples = 0
    }
    func stop() {
        if isCapturing { message = "已停止保存。照片已保留，可重建或在 Finder 查看。" }
        lock.lock(); active = false; let pending = busy; let ticket = token; lock.unlock()
        isCapturing = false
        if pending, !isFinishing {
            isFinishing = true
            queue.async { [self] in DispatchQueue.main.async { [self] in
                guard token == ticket else { return }
                isFinishing = false
            } }
        }
    }
    func finish(completion: @escaping (URL?) -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        lock.lock(); active = false; lock.unlock()
        isCapturing = false
        queue.async { [self] in
            let result = folder
            DispatchQueue.main.async { self.isFinishing = false; completion(result) }
        }
    }
    func offer(_ frame: CameraFrame) {
        lock.lock()
        guard active, !busy, frame.received - lastTime >= 1,
              !guided || (guidedStep != nil && frame.received >= guidedStepStartedAt) else { lock.unlock(); return }
        busy = true; lastTime = frame.received
        let ticket = token
        let step = guidedStep
        let stepStartedAt = guidedStepStartedAt
        let filtersFrames = automatic
        // Enqueue before releasing the lock so finish's barrier includes this write.
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard let folder else { return }
            do {
                let raw = CIImage(cvPixelBuffer: frame.pixels)
                if let expectedImageSize, expectedImageSize != raw.extent.size {
                    throw NSError(domain: "ObjectScanCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "摄像头画幅发生变化。请固定手机方向、分辨率和焦距，重新开始扫描。"])
                }
                expectedImageSize = raw.extent.size
                var acceptedSample: AutoOrbitFrameGate.Sample?
                if filtersFrames {
                    if repeatEpoch != stepStartedAt {
                        repeatEpoch = stepStartedAt
                        repeats = 0
                    }
                    let verdict = automaticGate.evaluate(frame)
                    guard case .accept(let sample) = verdict else {
                        if case .unchanged = verdict { repeats += 1 } else { repeats = 0 }
                        let unchanged = repeats
                        DispatchQueue.main.async { [self] in
                            guard token == ticket, isCapturing else { return }
                            lock.lock(); let sameStage = guidedStepStartedAt == stepStartedAt; lock.unlock()
                            guard sameStage else { return }
                            automaticQuality = verdict.message
                            unchangedSamples = unchanged
                        }
                        return
                    }
                    repeats = 0
                    acceptedSample = sample
                }
                let crop = region.map { r in
                    CGRect(x: r.x * raw.extent.width, y: (1 - r.y - r.height) * raw.extent.height,
                           width: r.width * raw.extent.width, height: r.height * raw.extent.height).integral.intersection(raw.extent)
                } ?? raw.extent
                guard crop.width >= 160, crop.height >= 160,
                      let image = context.createCGImage(raw, from: crop) else {
                    throw NSError(domain: "ObjectScanCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "扫描区域太小。请扩大区域，至少保留 160 × 160 像素。"])
                }
                let filename = String(format: "view_%04d.jpg", records.count + 1)
                let url = folder.appendingPathComponent(filename)
                let staging = folder.appendingPathComponent(".pending-\(UUID().uuidString).jpg")
                var committed = false
                var published = false
                defer {
                    try? FileManager.default.removeItem(at: staging)
                    if published && !committed { try? FileManager.default.removeItem(at: url) }
                }
                guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                var frameRecord: [String: Any] = ["filename": filename, "sequence": frame.sequence, "receivedUptime": frame.received,
                                "savedAt": ISO8601DateFormatter().string(from: Date()),
                                "sourceWidth": Int(raw.extent.width), "sourceHeight": Int(raw.extent.height),
                                "width": image.width, "height": image.height]
                if let step { frameRecord["guidedStep"] = step.key }
                let nextRecords = records + [frameRecord]
                var manifest: [String: Any] = ["schema": 1, "source": source, "samplingSeconds": 1,
                    "mirrored": false, "overlays": false, "metricScaleCalibrated": false,
                    "capture": "Camo or AVFoundation RGB frames; camera poses and coverage are not measured", "frames": nextRecords]
                if let r = region { manifest["normalizedTopLeftCrop"] = [r.x, r.y, r.width, r.height] }
                if filtersFrames { manifest["samplingMode"] = "automaticVisualSampling" }
                try FileManager.default.moveItem(at: staging, to: url)
                published = true
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.deletingLastPathComponent().appendingPathComponent("capture.json"), options: .atomic)
                committed = true
                if let acceptedSample { automaticGate.commit(acceptedSample) }
                records = nextRecords
                let n = records.count
                lock.lock()
                if let step { recordedSteps[step, default: 0] += 1 }
                let counts = recordedSteps
                if n >= 180 { active = false }
                if let step, guidedStep == step, counts[step, default: 0] >= Self.maximumGuidedPhotosPerStep { guidedStep = nil }
                lock.unlock()
                DispatchQueue.main.async { [self] in
                    guard token == ticket else { return }
                    if filtersFrames { automaticQuality = nil; unchangedSamples = 0 }
                    guidedCounts = counts
                    count = n
                    if n >= 180 { isCapturing = false; message = "已保存 180 张。可以开始重建。" }
                }
            } catch {
                lock.lock(); active = false; lock.unlock()
                DispatchQueue.main.async { [self] in
                    guard token == ticket else { return }
                    isCapturing = false; message = "采集停止：\(error.localizedDescription)"
                }
            }
        }
        lock.unlock()
    }
}
#endif
