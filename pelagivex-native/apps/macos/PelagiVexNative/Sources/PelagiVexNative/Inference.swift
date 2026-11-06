#if os(macOS)
import Foundation
import CoreML
import CoreImage
import Metal
import VisionCore

struct Packet {
    let frame: CameraFrame
    let detections: [Detection]
    let prototypes: [Float]
    let contract: ModelContract?
    let names: [String]
    let preprocessMS: Double
    let inferenceMS: Double
    let postprocessMS: Double
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
    private let tracker = Tracker()

    init(folder: URL, compute: MLComputeUnits, device: MTLDevice) throws {
        contract = try JSONDecoder().decode(ModelContract.self, from: Data(contentsOf: folder.appendingPathComponent("model.json")))
        try contract.validate()
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

    func predict(_ frame: CameraFrame) throws -> Packet {
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
        guard let predictions = output.featureValue(for: contract.predictionName)?.multiArrayValue,
              let prototypes = output.featureValue(for: contract.prototypeName)?.multiArrayValue,
              predictions.shape.map(\.intValue) == [1,4+contract.classNames.count+contract.maskChannels,contract.predictionCount],
              prototypes.shape.map(\.intValue) == [1,contract.maskChannels,contract.prototypeHeight,contract.prototypeWidth] else {
            throw PipelineError.invalid("Unsupported runtime output layout. YOLO26/YOLOE require a separate adapter.")
        }
        let detected = try Decoder.decode(dense(predictions), classes: contract.classNames.count,
                                         channels: contract.maskChannels, anchors: contract.predictionCount)
        let tracked = tracker.update(detected, time: frame.received)
        let proto = try dense(prototypes)
        let done = ProcessInfo.processInfo.systemUptime
        return Packet(frame: frame, detections: tracked, prototypes: proto, contract: contract, names: contract.classNames,
                      preprocessMS: (pre-start)*1000, inferenceMS: (predicted-pre)*1000, postprocessMS: (done-predicted)*1000)
    }
}

final class Pipeline {
    let distance = DistanceEstimator()
    let packets = Snapshot<Packet>()
    let active = Snapshot<Int>()
    let captureMeter = FrameMeter()
    let inferenceMeter = FrameMeter()
    var onError: ((String) -> Void)?
    private let slot = LatestSlot<(CameraFrame,Int)>()
    private let queue = DispatchQueue(label: "pelagivex.inference", qos: .userInitiated)
    private var segmenter: Segmenter?
    private var failed = false
    func load(folder: URL, compute: MLComputeUnits, device: MTLDevice, completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async { [self] in
            do { let next = try Segmenter(folder: folder, compute: compute, device: device)
                segmenter = next; failed = false; completion(.success(next.contract.classNames.count))
            } catch { completion(.failure(error)) }
        }
    }
    func submit(_ frame: CameraFrame) {
        guard let generation = active.get() else { return }
        captureMeter.add(sequence: frame.sequence, finished: frame.received, received: frame.received)
        if slot.offer((frame,generation)) { queue.async { [self] in drain() } }
    }
    func stop() { active.set(nil); slot.clear(); packets.set(nil); captureMeter.reset(); inferenceMeter.reset(); distance.stop() }
    private func drain() {
        while let (frame, generation) = slot.take() {
            autoreleasepool {
                guard active.get() == generation else { return }
                do {
                    let packet: Packet
                    if let segmenter, !failed { packet = try segmenter.predict(frame) }
                    else { packet = Packet(frame: frame, detections: [], prototypes: [], contract: nil, names: [], preprocessMS: 0, inferenceMS: 0, postprocessMS: 0) }
                    if active.get() == generation {
                        if packet.contract != nil { inferenceMeter.add(sequence: frame.sequence, finished: ProcessInfo.processInfo.systemUptime, received: frame.received) }
                        packets.set(packet)
                        distance.submit(packet)
                    }
                } catch {
                    failed = true
                    if active.get() == generation { packets.set(nil); onError?(error.localizedDescription) }
                }
            }
        }
    }
}
#endif
