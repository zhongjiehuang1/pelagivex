#if os(macOS)
import Foundation
import CoreML
import CoreImage
import Metal
import VisionCore

struct Packet {
    let frame: CameraFrame
    let detections: [Detection]
    let tracks: [TrackSnapshot]
    let prototypes: [Float]
    let contract: ModelContract?
    let names: [String]
    let preprocessMS: Double
    let inferenceMS: Double
    let postprocessMS: Double
    var textGuided = false
    var sourceMask: InstanceMask?
    var refinement: RefinedFrame?
}

enum RecognitionMode: String, CaseIterable { case fast, text }

struct RecognitionConfiguration: Equatable {
    let mode: RecognitionMode
    let prompts: [String]
    let revision: Int
}

private func dense(_ array: MLMultiArray) throws -> [Float] {
    let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
    guard array.count <= 8_000_000 else { throw PipelineError.invalid("Model output exceeds memory budget.") }
    var expected = 1; var contiguous = true
    for d in shape.indices.reversed() { if strides[d] != expected { contiguous = false }; expected *= shape[d] }
    func offset(_ flat: Int) -> Int {
        if contiguous { return flat }
        var flat = flat, result = 0
        for d in shape.indices.reversed() { result += (flat % shape[d])*strides[d]; flat /= shape[d] }
        return result
    }
    switch array.dataType {
    case .float32:
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        if contiguous { return Array(UnsafeBufferPointer(start: ptr, count: array.count)) }
        return (0..<array.count).map { ptr[offset($0)] }
    case .float16:
        let ptr = array.dataPointer.assumingMemoryBound(to: Float16.self)
        if contiguous { return UnsafeBufferPointer(start: ptr, count: array.count).map(Float.init) }
        return (0..<array.count).map { Float(ptr[offset($0)]) }
    case .double:
        let ptr = array.dataPointer.assumingMemoryBound(to: Double.self)
        return (0..<array.count).map { Float(ptr[offset($0)]) }
    default: throw PipelineError.invalid("Floating-point model outputs required.")
    }
}

final class Segmenter {
    let contract: ModelContract
    private let model: MLModel
    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let tracker: Tracker
    private let studyTracker = LegacyStudyTracker()

    init(folder: URL, compute: MLComputeUnits, device: MTLDevice) throws {
        contract = try JSONDecoder().decode(ModelContract.self, from: Data(contentsOf: folder.appendingPathComponent("model.json")))
        try contract.validate()
        tracker = Tracker(confirmationHits: contract.isEndToEnd ? 2 : 1,
                          allowClassAgnosticRecovery: contract.isEndToEnd)
        let compiled = folder.appendingPathComponent("UniversalSeg.mlmodelc")
        let package = folder.appendingPathComponent("UniversalSeg.mlpackage")
        let modelURL = FileManager.default.fileExists(atPath: compiled.path) ? compiled : try MLModel.compileModel(at: package)
        let config = MLModelConfiguration(); config.computeUnits = compute
        model = try MLModel(contentsOf: modelURL, configuration: config)
        guard let input = model.modelDescription.inputDescriptionsByName[contract.inputName]?.imageConstraint,
              input.pixelsWide == contract.inputSize, input.pixelsHigh == contract.inputSize,
              model.modelDescription.outputDescriptionsByName[contract.predictionName] != nil,
              model.modelDescription.outputDescriptionsByName[contract.prototypeName] != nil else {
            throw PipelineError.invalid("Model and manifest disagree.")
        }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: contract.inputSize,
            kCVPixelBufferHeightKey as String: contract.inputSize,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess, let created else {
            throw PipelineError.invalid("Could not allocate preprocessing pool.")
        }
        pool = created
    }

    func predict(_ frame: CameraFrame, minimumConfidence: Float = 0.25, legacyStudy: Bool = false,
                 detailedTracking: Bool = false, focusedTrackID: Int? = nil) throws -> Packet {
        let start = ProcessInfo.processInfo.systemUptime
        let transform = Letterbox(width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels), size: contract.inputSize)
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess, let destination else {
            throw PipelineError.invalid("Preprocessing allocation failed.")
        }
        let bounds = CGRect(x: 0, y: 0, width: contract.inputSize, height: contract.inputSize)
        let image = CIImage(cvPixelBuffer: frame.pixels)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(transform.scale), y: CGFloat(transform.scale)))
            .transformed(by: CGAffineTransform(translationX: CGFloat(transform.padX), y: CGFloat(transform.padY)))
        let background = CIImage(color: CIColor(red: 114/255.0, green: 114/255.0, blue: 114/255.0)).cropped(to: bounds)
        context.render(image.composited(over: background).cropped(to: bounds), to: destination, bounds: bounds, colorSpace: rgb)
        let pre = ProcessInfo.processInfo.systemUptime
        let features = try MLDictionaryFeatureProvider(dictionary: [contract.inputName: MLFeatureValue(pixelBuffer: destination)])
        let output = try model.prediction(from: features)
        let predicted = ProcessInfo.processInfo.systemUptime
        let expectedPredictionShape = contract.isEndToEnd
            ? [1, contract.predictionCount, 6+contract.maskChannels]
            : [1, 4+contract.classNames.count+contract.maskChannels, contract.predictionCount]
        guard let predictions = output.featureValue(for: contract.predictionName)?.multiArrayValue,
              let prototypes = output.featureValue(for: contract.prototypeName)?.multiArrayValue,
              predictions.shape.map(\.intValue) == expectedPredictionShape,
              prototypes.shape.map(\.intValue) == [1,contract.maskChannels,contract.prototypeHeight,contract.prototypeWidth] else {
            throw PipelineError.invalid("The runtime segmentation outputs differ from their verified model contract.")
        }
        let detected: [Detection]
        if contract.isEndToEnd {
            guard !legacyStudy else { throw PipelineError.invalid("Historical study recording requires its YOLO11 baseline.") }
            func decodeRows(_ values: UnsafeBufferPointer<Float>) throws -> [Detection] {
                try Decoder.decodeEndToEnd(values, classes: contract.classNames.count,
                                           channels: contract.maskChannels, proposals: contract.predictionCount,
                                           confidence: 0.10, limit: 100)
            }
            let stride = 6 + contract.maskChannels
            let count = contract.predictionCount * stride
            if predictions.dataType == .float32, predictions.count == count,
               predictions.strides.map(\.intValue) == [count, stride, 1] {
                detected = try predictions.withUnsafeBufferPointer(ofType: Float.self, decodeRows)
            } else {
                detected = try dense(predictions).withUnsafeBufferPointer(decodeRows)
            }
        } else {
            detected = try Decoder.decode(dense(predictions), classes: contract.classNames.count,
                                         channels: contract.maskChannels, anchors: contract.predictionCount,
                                         confidence: legacyStudy ? 0.35 : 0.10, limit: legacyStudy ? 25 : 100)
        }
        let tracked = legacyStudy ? studyTracker.update(detected, time: frame.received)
            : tracker.update(detected, time: frame.received, newTrackThreshold: minimumConfidence,
                             maximumMissingSeconds: detailedTracking ? 4 : 0.8, focusedTrackID: focusedTrackID)
        let proto = try dense(prototypes)
        let done = ProcessInfo.processInfo.systemUptime
        return Packet(frame: frame, detections: tracked, tracks: legacyStudy ? [] : tracker.snapshots,
                      prototypes: proto, contract: contract, names: contract.classNames,
                      preprocessMS: (pre-start)*1000, inferenceMS: (predicted-pre)*1000, postprocessMS: (done-predicted)*1000)
    }

    func resetTracking() { tracker.reset(); studyTracker.reset() }
}

/// Frozen first-study association, used only by --pair-trace to reproduce its original inputs.
private final class LegacyStudyTracker {
    private var previous: [Detection] = []
    private var nextID = 1
    private var lastTime = 0.0
    func reset() { previous = []; lastTime = 0 }
    func update(_ items: [Detection], time: Double) -> [Detection] {
        if time-lastTime > 0.5 || time < lastTime { previous = [] }
        var used = Set<Int>()
        let output = items.map { observation -> Detection in
            var item = observation
            let match = previous.enumerated().filter { !used.contains($0.offset) && $0.element.classID == item.classID }
                .max { $0.element.box.iou(item.box) < $1.element.box.iou(item.box) }
            if let match, match.element.box.iou(item.box) >= 0.3 {
                used.insert(match.offset); item.trackID = match.element.trackID
            } else { item.trackID = nextID; nextID = nextID == 1000000 ? 1 : nextID+1 }
            return item
        }
        previous = output; lastTime = time
        return output
    }
}

final class Pipeline {
    let distance = DistanceEstimator()
    let comparison = PairRuntime()
    let packets = Snapshot<Packet>()
    let active = Snapshot<Int>()
    let captureMeter = FrameMeter()
    let inferenceMeter = FrameMeter()
    let minimumConfidence = Snapshot<Float>()
    let recognitionStatus = Snapshot<String>()
    let refineContours = Snapshot<Bool>()
    let liveFocusTrackID = Snapshot<Int>()
    let ambientDepthEnabled = Snapshot<Bool>()
    let contourRefiner = AsyncContourRefiner()
    private let recognition = Snapshot<RecognitionConfiguration>()
    var onError: ((String) -> Void)?
    private let slot = LatestSlot<(CameraFrame,Int)>()
    private let queue = DispatchQueue(label: "pelagivex.inference", qos: .userInitiated)
    private var segmenter: Segmenter?
    private var failed = false
    private let textDetector = OpenVocabularyDetector()
    private var lastConfiguration: RecognitionConfiguration?
    private var textFailure: RecognitionConfiguration?
    private var wasRefining = false
    private let settingsLock = NSLock()
    private var settingsRevision = 0
    init() {
        minimumConfidence.set(0.25)
        refineContours.set(true)
        recognition.set(RecognitionConfiguration(mode: .fast, prompts: [], revision: 0))
    }
    func setRecognition(mode: RecognitionMode, prompts: [String]) {
        settingsLock.lock()
        settingsRevision += 1
        recognition.set(RecognitionConfiguration(mode: mode, prompts: prompts, revision: settingsRevision))
        settingsLock.unlock()
        liveFocusTrackID.set(nil)
        packets.set(nil); inferenceMeter.reset(); comparison.reset(); distance.stop(); textDetector.stop(); contourRefiner.reset()
        recognitionStatus.set(mode == .text ? "Text-guided recognition: waiting for a frame…" : nil)
    }
    func load(folder: URL, compute: MLComputeUnits, device: MTLDevice,
              completion: @escaping (Result<(classes: Int, name: String), Error>) -> Void) {
        queue.async { [self] in
            do { let next = try Segmenter(folder: folder, compute: compute, device: device)
                segmenter = next; failed = false
                completion(.success((next.contract.classNames.count, next.contract.modelName ?? "Local instance segmenter")))
            } catch { completion(.failure(error)) }
        }
    }
    func submit(_ frame: CameraFrame) {
        guard let generation = active.get() else { return }
        captureMeter.add(sequence: frame.sequence, finished: frame.received, received: frame.received)
        if slot.offer((frame,generation)) { queue.async { [self] in drain() } }
    }
    func stop() {
        active.set(nil); slot.clear(); packets.set(nil); captureMeter.reset(); inferenceMeter.reset()
        liveFocusTrackID.set(nil)
        comparison.reset(); distance.stop()
        textDetector.stop(); contourRefiner.reset()
        queue.async { [self] in
            segmenter?.resetTracking(); textDetector.resetTracking()
            lastConfiguration = nil; textFailure = nil
        }
    }
    private func drain() {
        while let (frame, generation) = slot.take() {
            autoreleasepool {
                guard active.get() == generation else { return }
                guard let configuration = recognition.get() else { return }
                do {
                    if configuration != lastConfiguration {
                        segmenter?.resetTracking(); textDetector.resetTracking()
                        lastConfiguration = configuration; textFailure = nil; contourRefiner.reset()
                    }
                    let refining = refineContours.get() ?? false
                    if refining != wasRefining { contourRefiner.reset(); wasRefining = refining }
                    let packet: Packet
                    if configuration.mode == .text, textFailure != configuration {
                        recognitionStatus.set("Searching selected categories locally…")
                        packet = try textDetector.predict(frame, prompts: configuration.prompts,
                                                          threshold: minimumConfidence.get() ?? 0.25)
                        if recognition.get() == configuration {
                            recognitionStatus.set("OWLv2 + SAM 2 · local object contours · \(configuration.prompts.count) categories")
                        }
                    } else if configuration.mode == .fast, let segmenter, !failed {
                        var detected = try segmenter.predict(frame, minimumConfidence: minimumConfidence.get() ?? 0.25,
                                                             focusedTrackID: liveFocusTrackID.get())
                        guard active.get() == generation, recognition.get() == configuration else { return }
                        if refining {
                            contourRefiner.submit(detected, focusedTrackID: liveFocusTrackID.get())
                            detected.refinement = contourRefiner.result.get()
                            recognitionStatus.set(contourRefiner.failure.get().map { "Detailed refinement unavailable: \($0)" }
                                ?? "Live recognition · fine contours updated in background")
                        } else {
                            recognitionStatus.set("Automatic object recognition · real-time contours")
                        }
                        packet = detected
                    }
                    else { packet = Packet(frame: frame, detections: [], tracks: [], prototypes: [], contract: nil, names: [], preprocessMS: 0, inferenceMS: 0, postprocessMS: 0) }
                    if active.get() == generation, recognition.get() == configuration {
                        if packet.contract != nil || packet.textGuided { inferenceMeter.add(sequence: frame.sequence, finished: ProcessInfo.processInfo.systemUptime, received: frame.received) }
                        packets.set(packet)
                        comparison.process(packet, distance: distance, ambientDepthEnabled: ambientDepthEnabled.get() ?? true)
                    }
                } catch {
                    guard active.get() == generation, recognition.get() == configuration else { return }
                    packets.set(nil)
                    if configuration.mode == .text {
                        textFailure = configuration
                        recognitionStatus.set("Text-guided recognition unavailable: \(error.localizedDescription). Apply categories to retry.")
                    } else {
                        failed = true; onError?(error.localizedDescription)
                    }
                }
            }
        }
    }
}
#endif
