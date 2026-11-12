#if os(macOS)
import CoreImage
import CoreVideo
import Foundation
import Metal
import VisionCore

struct PairTrace: Codable {
    let source: String
    let frames: [PairTraceFrame]
}

struct PairTraceFrame: Codable {
    let time: Double
    let depthSeconds: Double?
    let detections: [PairTraceDetection]
}

struct PairTraceDetection: Codable {
    let id: Int
    let name: String
    let box: [Float]
    let score: Float
    let depth: Double?
    let reference: Double?
}

private struct PairCaptureManifest: Decodable {
    struct Frame: Decodable {
        let time: Double
        let image: String
        let depth: String
    }
    let source: String
    let depthUnitsPerMetre: Double
    let frames: [Frame]
}

enum PairTraceCommand {
    static func runAndExit() -> Never {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first {
            case "--pair-trace":
                guard args.count == 3 else {
                    throw PipelineError.invalid("Usage: --pair-trace <RGB-D manifest.json> <trace.json>")
                }
                let manifest = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
                let trace = try record(manifestURL: manifest)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(trace).write(to: output, options: .atomic)
                print("Saved \(trace.frames.count) frames: \(output.path)")
            case "--pair-replay":
                let usage = "Usage: --pair-replay <trace.json> <track A> <track B> [independent-reference.json] [--cap <calls>]"
                guard args.count >= 4, let a = Int(args[2]), let b = Int(args[3]) else {
                    throw PipelineError.invalid(usage)
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
                let decoder = JSONDecoder()
                var options = ArraySlice(args.dropFirst(4))
                var reference: PairIndependentReference?
                if let path = options.first, path != "--cap" {
                    reference = try decoder.decode(PairIndependentReference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                    options.removeFirst()
                }
                var cap: Int?
                if !options.isEmpty {
                    guard options.count == 2, options.first == "--cap", let last = options.last, let value = Int(last), value > 0 else {
                        throw PipelineError.invalid(usage)
                    }
                    cap = value
                }
                print(try PairReplay.run(trace: decoder.decode(PairTrace.self, from: data), a: a, b: b, reference: reference, cap: cap))
            case "--tracking-replay":
                guard args.count == 3 else {
                    throw PipelineError.invalid("Usage: --tracking-replay <trace.json> <comma-separated original IDs for one verified object>")
                }
                let fields = args[2].split(separator: ",", omittingEmptySubsequences: false)
                let aliases = fields.compactMap { Int($0) }
                guard aliases.count == fields.count, !aliases.isEmpty else {
                    throw PipelineError.invalid("Provide comma-separated integer track aliases for the same manually verified object.")
                }
                let trace = try JSONDecoder().decode(PairTrace.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
                print(try TrackingReplay.run(trace: trace, aliases: aliases))
            default:
                throw PipelineError.invalid("Expected --pair-trace or --pair-replay.")
            }
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Pair study: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func record(manifestURL: URL) throws -> PairTrace {
        let manifest = try JSONDecoder().decode(PairCaptureManifest.self, from: Data(contentsOf: manifestURL))
        guard !manifest.frames.isEmpty, manifest.frames.count <= 1_000,
              manifest.depthUnitsPerMetre.isFinite, manifest.depthUnitsPerMetre > 0 else {
            throw PipelineError.invalid("Provide 1–1,000 RGB-D frames and a positive depth scale.")
        }
        var lastTime = -Double.infinity
        for frame in manifest.frames {
            guard frame.time.isFinite, frame.time >= 0, frame.time > lastTime else {
                throw PipelineError.invalid("Frame times must be finite, nonnegative and strictly increasing.")
            }
            lastTime = frame.time
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let resources = Bundle.main.resourceURL else {
            throw PipelineError.invalid("Run the executable inside the built PelagiVex.app on a Metal-enabled Mac.")
        }

        let legacy = resources.appendingPathComponent("LegacyStudyModel")
        let model = FileManager.default.fileExists(atPath: legacy.appendingPathComponent("model.json").path)
            ? legacy : resources.appendingPathComponent("Model")
        let segmenter = try Segmenter(folder: model, compute: .all, device: device)
        let worker = DistanceEstimator()
        defer { worker.stop() }
        let root = manifestURL.deletingLastPathComponent()
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        var warmed = false
        var frames = [PairTraceFrame]()
        for (index, frame) in manifest.frames.enumerated() {
            let captured = CameraFrame(pixels: try readImage(root.appendingPathComponent(frame.image), context: context),
                                       sequence: UInt64(index + 1), received: frame.time)
            // Preserve the input policy used by the published first pair study.
            let packet = try segmenter.predict(captured, legacyStudy: true)
            var depth: DistanceResult?
            if !packet.detections.isEmpty {
                let reference = ReferenceDepth(file: root.appendingPathComponent(frame.depth),
                                               unitsPerMetre: manifest.depthUnitsPerMetre)
                if !warmed {
                    _ = try measure(packet, worker: worker, reference: reference)
                    warmed = true
                }
                depth = try measure(packet, worker: worker, reference: reference)
            }
            let width = CVPixelBufferGetWidth(captured.pixels), height = CVPixelBufferGetHeight(captured.pixels)
            let letterbox = Letterbox(width: width, height: height, size: segmenter.contract.inputSize)
            let entries = packet.detections.map { detection in
                let box = letterbox.source(detection.box)
                let normalized = [box.x1 / Float(width), box.y1 / Float(height), box.x2 / Float(width), box.y2 / Float(height)]
                    .map { min(1, max(0, $0)) }
                return PairTraceDetection(id: detection.trackID, name: packet.names[detection.classID], box: normalized,
                                          score: detection.score, depth: depth?.values[detection.trackID],
                                          reference: depth?.referenceValues[detection.trackID])
            }
            frames.append(PairTraceFrame(time: frame.time, depthSeconds: depth?.workerSeconds, detections: entries))
            if (index + 1) % 20 == 0 { fputs("Analyzed \(index + 1)/\(manifest.frames.count) frames\n", stderr) }
        }
        return PairTrace(source: manifest.source, frames: frames)
    }

    private static func readImage(_ url: URL, context: CIContext) throws -> CVPixelBuffer {
        guard let image = CIImage(contentsOf: url), image.extent.width > 0, image.extent.height > 0,
              image.extent.width <= 4_096, image.extent.height <= 4_096 else {
            throw PipelineError.invalid("Invalid benchmark RGB frame: \(url.lastPathComponent)")
        }
        var pixels: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let size = image.extent.size
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pixels) == kCVReturnSuccess,
              let pixels else { throw PipelineError.invalid("Unable to allocate a benchmark frame.") }
        context.render(image, to: pixels)
        return pixels
    }

    private static func measure(_ packet: Packet, worker: DistanceEstimator, reference: ReferenceDepth) throws -> DistanceResult {
        let completed = DispatchSemaphore(value: 0)
        let result = Snapshot<DistanceResult>()
        guard worker.submit(packet, minimumInterval: 0, reference: reference, completion: { measurement in
            result.set(measurement)
            completed.signal()
        }) else { throw PipelineError.invalid("Depth worker is busy during serial replay.") }
        guard completed.wait(timeout: .now() + 120) == .success, let measurement = result.get() else {
            throw PipelineError.invalid(worker.status.get() ?? "Depth worker did not produce a measurement.")
        }
        return measurement
    }
}
#endif
