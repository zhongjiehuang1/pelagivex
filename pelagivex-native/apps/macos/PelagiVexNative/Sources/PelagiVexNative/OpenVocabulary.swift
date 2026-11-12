#if os(macOS)
import AppKit
import CoreImage
import Foundation
import ImageIO
import Darwin
import VisionCore

/// A local process, not a web service. It returns boxes from the exact submitted frame.
final class OpenVocabularyDetector {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var generation = 0
    private let tracker = Tracker()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func resetTracking() { tracker.reset() }

    func currentGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func stop() {
        lock.lock()
        generation += 1
        let running = process
        process = nil; input = nil; output = nil
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    func predict(_ frame: CameraFrame, prompts: [String], threshold: Float) throws -> Packet {
        guard (1...32).contains(prompts.count), prompts.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else {
            throw PipelineError.invalid("Enter 1–32 object names, each up to 128 characters.")
        }
        let (response, preparationMS, roundtripMS) = try request(frame, fields: [
            "prompts": prompts, "threshold": 0.10, "refineOutlines": true
        ])
        guard let entries = response["detections"] as? [[String: Any]], entries.count <= 100,
              let seconds = response["workerSeconds"] as? Double, seconds.isFinite, seconds >= 0 else {
            throw PipelineError.invalid("Invalid local recognition response.")
        }
        let width = CVPixelBufferGetWidth(frame.pixels), height = CVPixelBufferGetHeight(frame.pixels)
        let geometry = Letterbox(width: width, height: height, size: 768)
        var detections: [Detection] = []
        for item in entries {
            guard let label = item["label"] as? String, let classID = prompts.firstIndex(of: label),
                  let confidence = item["confidence"] as? Double, confidence.isFinite, (0...1).contains(confidence),
                  let coordinates = item["box"] as? [Double], coordinates.count == 4,
                  coordinates.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw PipelineError.invalid("Invalid box or category from the local recognizer.")
            }
            let box = Box(Float(coordinates[0] * Double(width)) * geometry.scale + geometry.padX,
                          Float(coordinates[1] * Double(height)) * geometry.scale + geometry.padY,
                          Float(coordinates[2] * Double(width)) * geometry.scale + geometry.padX,
                          Float(coordinates[3] * Double(height)) * geometry.scale + geometry.padY)
            guard box.valid else { throw PipelineError.invalid("Empty recognition box.") }
            detections.append(Detection(classID: classID, score: Float(confidence), box: box, coefficients: [],
                                        classConfidences: [ClassConfidence(classID: classID, score: Float(confidence))]))
        }
        let tracked = tracker.update(detections, time: frame.received, newTrackThreshold: threshold,
                                     maximumMissingSeconds: 4)
        var lookup = Array(repeating: UInt8(0), count: detections.count + 1)
        for (index, original) in detections.enumerated() {
            if let drawn = tracked.firstIndex(where: { $0.classID == original.classID && $0.box == original.box && $0.score == original.score }) {
                lookup[index+1] = UInt8(drawn+1)
            }
        }
        let sourceMask = try decodeMask(response, instanceCount: detections.count)?.remapped(lookup, instanceCount: tracked.count)
        guard sourceMask != nil || detections.isEmpty else {
            throw PipelineError.invalid(response["segmentationError"] as? String ?? "Detailed object contours were not returned.")
        }
        return Packet(frame: frame, detections: tracked, tracks: tracker.snapshots, prototypes: [], contract: nil,
                      names: prompts, preprocessMS: preparationMS, inferenceMS: seconds * 1000,
                      postprocessMS: max(0, roundtripMS - seconds * 1000), textGuided: true, sourceMask: sourceMask)
    }

    func refine(_ packet: Packet, expectedGeneration: Int? = nil) throws -> Packet {
        guard !packet.detections.isEmpty, let contract = packet.contract else { return packet }
        let width = CVPixelBufferGetWidth(packet.frame.pixels), height = CVPixelBufferGetHeight(packet.frame.pixels)
        let geometry = Letterbox(width: width, height: height, size: contract.inputSize)
        let targets: [[String: Any]] = packet.detections.map {
            let box = geometry.source($0.box)
            let coordinates = [box.x1/Float(width), box.y1/Float(height), box.x2/Float(width), box.y2/Float(height)]
                .map { min(1, max(0, $0)) }
            return ["label": packet.names[$0.classID], "confidence": $0.score, "box": coordinates]
        }
        let (response, preparationMS, roundtripMS) = try request(packet.frame, fields: [
            "refineDetections": targets, "refineOutlines": true
        ], expectedGeneration: expectedGeneration)
        guard let seconds = response["workerSeconds"] as? Double, seconds.isFinite, seconds >= 0,
              let mask = try decodeMask(response, instanceCount: packet.detections.count) else {
            throw PipelineError.invalid(response["segmentationError"] as? String ?? "Detailed automatic contours were not returned.")
        }
        return Packet(frame: packet.frame, detections: packet.detections, tracks: packet.tracks,
                      prototypes: packet.prototypes, contract: packet.contract, names: packet.names,
                      preprocessMS: packet.preprocessMS + preparationMS,
                      inferenceMS: packet.inferenceMS + seconds * 1000,
                      postprocessMS: packet.postprocessMS + max(0, roundtripMS - seconds * 1000), sourceMask: mask)
    }

    private func decodeMask(_ response: [String: Any], instanceCount: Int) throws -> InstanceMask? {
        guard let payload = response["instanceMask"] as? [String: Any] else { return nil }
        guard let width = payload["width"] as? Int, let height = payload["height"] as? Int,
              (1...2048).contains(width), (1...2048).contains(height),
              let encoded = payload["data"] as? String, encoded.count <= 6_000_000,
              let data = Data(base64Encoded: encoded), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height,
              image.bitsPerComponent == 8, image.bitsPerPixel == 8,
              image.colorSpace?.model == .monochrome, let provider = image.dataProvider?.data,
              let raw = CFDataGetBytePtr(provider), CFDataGetLength(provider) >= image.bytesPerRow * height else {
            throw PipelineError.invalid("Invalid detailed instance-mask image.")
        }
        var pixels = [UInt8](); pixels.reserveCapacity(width * height)
        for y in 0..<height {
            pixels.append(contentsOf: UnsafeBufferPointer(start: raw + y * image.bytesPerRow, count: width))
        }
        return try InstanceMask(width: width, height: height, pixels: pixels, instanceCount: instanceCount)
    }

    private func request(_ frame: CameraFrame, fields: [String: Any],
                         expectedGeneration: Int? = nil) throws -> ([String: Any], Double, Double) {
        lock.lock(); let ticket = generation; let needsLaunch = process == nil; lock.unlock()
        if let expectedGeneration, expectedGeneration != ticket {
            throw PipelineError.invalid("Recognition was cancelled.")
        }
        if needsLaunch { try launch(ticket: ticket) }
        lock.lock()
        let writer = input, reader = output, current = generation == ticket
        lock.unlock()
        guard current, let writer, let reader else { throw PipelineError.invalid("Recognition was cancelled.") }
        let started = ProcessInfo.processInfo.systemUptime
        let width = CVPixelBufferGetWidth(frame.pixels), height = CVPixelBufferGetHeight(frame.pixels)
        let scale = min(1, 1280.0 / Double(max(width, height)))
        let image = CIImage(cvPixelBuffer: frame.pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            throw PipelineError.invalid("Could not prepare the recognition frame.")
        }
        var payload = fields
        payload["image"] = jpeg.base64EncodedString()
        var bytes = try JSONSerialization.data(withJSONObject: payload); bytes.append(10)
        let prepared = ProcessInfo.processInfo.systemUptime
        do {
            try writer.write(contentsOf: bytes)
            let response = try readJSON(reader)
            if let error = response["error"] as? String { throw PipelineError.invalid(error) }
            lock.lock(); let stillCurrent = generation == ticket; lock.unlock()
            guard stillCurrent else { throw PipelineError.invalid("Recognition was cancelled.") }
            return (response, (prepared-started)*1000, (ProcessInfo.processInfo.systemUptime-prepared)*1000)
        } catch { stop(); throw error }
    }

    private func launch(ticket: Int) throws {
        var root = Bundle.main.bundleURL
        for _ in 0..<6 { root.deleteLastPathComponent() }
        if let override = ProcessInfo.processInfo.environment["PELAGIVEX_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        }
        let python = root.appendingPathComponent(".venv-model/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".cache/owlv2/model.safetensors").path),
              let script = Bundle.main.url(forResource: "open_vocab_worker", withExtension: "py") else {
            throw PipelineError.invalid("Local OWLv2 environment or weights not found in this checkout.")
        }
        let task = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        // A cancellation can close the worker's read end while JPEG encoding finishes.
        // Deliver a write error to the caller instead of terminating the app with SIGPIPE.
        guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw PipelineError.invalid("Could not configure the local recognition worker pipe.")
        }
        task.executableURL = python; task.arguments = ["-B", script.path, root.path]
        task.standardInput = stdinPipe; task.standardOutput = stdoutPipe; task.standardError = FileHandle.nullDevice
        lock.lock()
        guard generation == ticket else { lock.unlock(); throw PipelineError.invalid("Text recognition was cancelled.") }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        lock.unlock()
        do {
            let ready = try readJSON(stdoutPipe.fileHandleForReading)
            guard ready["ready"] as? Bool == true else {
                throw PipelineError.invalid(ready["error"] as? String ?? "Local OWLv2 failed to load.")
            }
        } catch { stop(); throw error }
    }

    private func readJSON(_ handle: FileHandle) throws -> [String: Any] {
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while bytes.count < 6_500_000 {
            // POSIX pipe reads return available bytes; a 64 KiB buffer does not wait
            // for 64 KiB. Avoid one system call for every byte of the PNG response.
            let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw PipelineError.invalid("Local text detector stopped.")
            }
            if let newline = chunk[..<count].firstIndex(of: 10) {
                guard bytes.count + newline < 6_500_000 else {
                    throw PipelineError.invalid("Local text detector response is too large.")
                }
                bytes.append(contentsOf: chunk[..<newline])
                return try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
            }
            bytes.append(contentsOf: chunk[..<count])
        }
        throw PipelineError.invalid("Local text detector response is too large.")
    }
}
#endif
