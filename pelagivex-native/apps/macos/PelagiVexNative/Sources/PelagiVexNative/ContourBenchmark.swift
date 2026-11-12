#if os(macOS)
import Foundation
import CoreImage
import CoreVideo
import Metal
import VisionCore
import CryptoKit

/// Repeatable scheduler stress test on public saved frames, not a camera or accuracy test.
enum ContourBenchmark {
    static func runAndExit() -> Never {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 5, ["serial", "async"].contains(args[1]),
                  let duration = Double(args[4]), (6...120).contains(duration),
                  let device = MTLCreateSystemDefaultDevice(), let resources = Bundle.main.resourceURL else {
                throw PipelineError.invalid("Usage: --contour-benchmark <serial|async> <RGB folder> <result.json> <seconds 6..120>")
            }
            let serial = args[1] == "serial", folder = URL(fileURLWithPath: args[2])
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { throw PipelineError.invalid("No saved RGB frames.") }
            let selected = Array(files.prefix(120))
            let context = CIContext(mtlDevice: device)
            let buffers: [CVPixelBuffer] = try selected.map { url in
                guard let image = CIImage(contentsOf: url) else { throw PipelineError.invalid("Invalid saved frame.") }
                var buffer: CVPixelBuffer?
                let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                guard CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height),
                    kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
                    throw PipelineError.invalid("Saved frame allocation failed.")
                }
                context.render(image, to: buffer)
                return buffer
            }
            let environment = ProcessInfo.processInfo.environment
            let modelFolder = environment["PELAGIVEX_BENCH_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
                ?? resources.appendingPathComponent("Model")
            let computeName = environment["PELAGIVEX_BENCH_COMPUTE"] ?? "all"
            guard ["all", "cpuAndNeuralEngine", "cpuAndGPU"].contains(computeName) else {
                throw PipelineError.invalid("Benchmark compute must be all, cpuAndGPU or cpuAndNeuralEngine.")
            }
            let detector = try Segmenter(folder: modelFolder,
                compute: computeName == "all" ? .all : computeName == "cpuAndGPU" ? .cpuAndGPU : .cpuAndNeuralEngine, device: device)
            let warmupStarted = ProcessInfo.processInfo.systemUptime
            for index in 0..<5 {
                _ = try detector.predict(CameraFrame(pixels: buffers[index % buffers.count], sequence: UInt64(index),
                    received: ProcessInfo.processInfo.systemUptime))
            }
            detector.resetTracking()
            let modelWarmupSeconds = ProcessInfo.processInfo.systemUptime - warmupStarted
            let worker = OpenVocabularyDetector(), async = AsyncContourRefiner()
            var observations: [[String: Any]] = [], lastTick = -1
            var serialFailure: String?, serialSubmissions = 0, serialCompletions = 0
            let start = ProcessInfo.processInfo.systemUptime
            while serialFailure == nil && ProcessInfo.processInfo.systemUptime - start < duration {
                let now = ProcessInfo.processInfo.systemUptime
                let tick = Int((now-start)*30)
                if tick == lastTick { Thread.sleep(forTimeInterval: 0.001); continue }
                lastTick = tick
                try autoreleasepool {
                    let frame = CameraFrame(pixels: buffers[tick % buffers.count], sequence: UInt64(tick+1), received: now)
                    let packet = try detector.predict(frame)
                    var samMS = 0.0
                    var serialFineObjects = 0, serialSucceeded = false
                    if serial, !packet.detections.isEmpty {
                        serialSubmissions += 1
                        do {
                            let refined = try worker.refine(packet)
                            guard let mask = refined.sourceMask else { throw PipelineError.invalid("SAM returned no mask.") }
                            samMS = refined.inferenceMS - packet.inferenceMS
                            serialFineObjects = mask.representedInstances.filter { $0 != 0 }.count
                            serialSucceeded = true; serialCompletions += 1
                        } catch { serialFailure = error.localizedDescription }
                    } else if !serial { async.submit(packet) }
                    let end = ProcessInfo.processInfo.systemUptime
                    var row: [String: Any] = ["time": end-start, "sourceIndex": tick % buffers.count,
                        "sequence": tick+1, "objects": packet.detections.count,
                        "modelMS": packet.inferenceMS, "latencyMS": (end-now)*1000]
                    row["eligibleFineObjects"] = serialFineObjects
                    row["geometricallyEligibleObjects"] = serialSucceeded ? packet.detections.count : 0
                    if serial {
                        row["samWorkerMS"] = samMS
                        row["serialSAMCompleted"] = serialSucceeded
                    }
                    if let result = async.result.get() {
                        row["samAgeSeconds"] = end-result.received
                        row["samWorkerMS"] = result.workerMS
                        row["samSourceSequence"] = result.sequence
                        row["samSourceReceivedSeconds"] = result.received-start
                        let warps = ContourPropagation.warps(source: result.detections, current: packet.detections,
                            sourceWidth: result.width, sourceHeight: result.height,
                            currentWidth: CVPixelBufferGetWidth(frame.pixels), currentHeight: CVPixelBufferGetHeight(frame.pixels),
                            inputSize: detector.contract.inputSize, sourceReceived: result.received,
                            currentReceived: frame.received, now: end)
                        row["geometricallyEligibleObjects"] = warps.count
                        row["eligibleFineObjects"] = warps.filter { result.representedInstances.contains(UInt8($0.sourceIndex+1)) }.count
                        row["samSourceObjects"] = result.detections.count
                        row["representedSAMObjects"] = result.representedInstances.filter { $0 != 0 }.count
                    }
                    row["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
                    observations.append(row)
                }
            }
            let refinementFailure = serialFailure ?? async.failure.get()
            let samplerCounts = async.counts.get() ?? RefinementCounts()
            let successfulSAM = serial ? serialCompletions
                : Set(observations.compactMap { $0["samSourceSequence"] as? UInt64 }).count
            worker.stop(); async.reset()
            let warm = observations.filter { let time = $0["time"] as! Double; return time >= 5 && time <= duration }
            let successfulWarmSAM = serial ? warm.filter { $0["serialSAMCompleted"] as? Bool == true }.count
                : Set(warm.filter { ($0["samSourceReceivedSeconds"] as? Double ?? -1) >= 5 }
                    .compactMap { $0["samSourceSequence"] as? UInt64 }).count
            let validFineComparison = refinementFailure == nil && successfulWarmSAM > 0
            let latencies = warm.map { $0["latencyMS"] as! Double }.sorted()
            func percentile(_ fraction: Double) -> Double {
                latencies.isEmpty ? 0 : latencies[min(latencies.count-1, Int(Double(latencies.count-1)*fraction))]
            }
            let report: [String: Any] = ["mode": args[1], "seconds": duration, "warmupSeconds": 5,
                "inputRateFPS": 30, "warmObservedFPS": Double(warm.count)/max(0.001,duration-5),
                "latencyP50MS": percentile(0.5), "latencyP95MS": percentile(0.95),
                "validForFineContourComparison": validFineComparison,
                "successfulObservedSAMResults": successfulSAM,
                "successfulWarmObservedSAMResults": successfulWarmSAM,
                "actualSAMSubmissions": serial ? serialSubmissions : samplerCounts.submitted,
                "actualSAMCompletions": serial ? serialCompletions : samplerCounts.completed,
                "actualSAMFailures": serial ? (serialFailure == nil ? 0 : 1) : samplerCounts.failed,
                "refinementFailure": refinementFailure as Any? ?? NSNull(),
                "modelFolder": modelFolder.path, "computeUnits": computeName,
                "modelPrewarmCalls": 5, "modelPrewarmSeconds": modelWarmupSeconds,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "processorCount": ProcessInfo.processInfo.processorCount,
                "metalDevice": device.name,
                "modelManifestSHA256": try SHA256.hash(data: Data(contentsOf: modelFolder.appendingPathComponent("model.json"))).map { String(format: "%02x", $0) }.joined(),
                "samBackend": "Production PyTorch MPS SAM2.1 Tiny FP32",
                "sourceFiles": selected.map(\.path), "observations": observations,
                "fineCountScope": "Serial counts current source-mask instances with pixels. Async counts instances with pixels passing current identity, age and geometry checks. Neither is boundary accuracy.",
                "scope": "Offline public-frame scheduler stress test, first 120 frames cycled at 30 input frames/s; excludes rendering and depth; not an accuracy test or original video timing."]
            let output = URL(fileURLWithPath: args[3])
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("\(args[1]): \(warm.count) warm frames, \(report["warmObservedFPS"]!) FPS, P95 \(percentile(0.95)) ms")
            guard validFineComparison else {
                throw PipelineError.invalid("Saved invalid fine-contour benchmark: SAM failed or produced no observed result.")
            }
            exit(EXIT_SUCCESS)
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(EXIT_FAILURE) }
    }
}
#endif
