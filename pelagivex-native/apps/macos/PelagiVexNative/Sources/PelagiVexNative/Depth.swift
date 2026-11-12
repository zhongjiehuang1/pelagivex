#if os(macOS)
import Foundation
import CoreImage
import AppKit
import VisionCore

struct DistanceResult {
    let received: Double
    let sequence: UInt64
    let values: [Int: Double]
    let referenceValues: [Int: Double]
    let workerSeconds: Double
}

struct ReferenceDepth {
    let file: URL
    let unitsPerMetre: Double
}

/// Runs the existing local indoor depth model off the segmentation queue.
final class DistanceEstimator {
    let result = Snapshot<DistanceResult>()
    let status = Snapshot<String>()
    private let queue = DispatchQueue(label: "pelagivex.depth", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var generation = 0
    private var lastSubmission = 0.0
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func stop() {
        lock.lock()
        generation += 1
        let activeProcess = process
        lock.unlock()
        result.set(nil); status.set(nil)
        // Interrupt a blocked model load or inference now, not after its queue drains.
        if let activeProcess, activeProcess.isRunning { activeProcess.terminate() }
        queue.async { [self] in
            lock.lock()
            if process === activeProcess { process = nil; input = nil; output = nil }
            lock.unlock()
            result.set(nil); status.set(nil)
        }
    }

    @discardableResult
    func submit(_ packet: Packet, minimumInterval: Double = 2, reference: ReferenceDepth? = nil,
                completion: ((DistanceResult?) -> Void)? = nil) -> Bool {
        guard packet.contract != nil, !packet.detections.isEmpty else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !busy, now - lastSubmission >= minimumInterval else { lock.unlock(); return false }
        busy = true; lastSubmission = now
        let ticket = generation
        lock.unlock()
        queue.async { [self] in
            var measured: DistanceResult?
            defer {
                lock.lock(); busy = false; lock.unlock()
                completion?(measured)
            }
            do {
                lock.lock(); let active = generation == ticket; let needsLaunch = process == nil; lock.unlock()
                guard active else { return }
                if needsLaunch { try launch(ticket: ticket) }
                guard let input, let output, let contract = packet.contract else { return }
                let width = CVPixelBufferGetWidth(packet.frame.pixels), height = CVPixelBufferGetHeight(packet.frame.pixels)
                let scale = min(1.0, 640.0 / Double(max(width, height)))
                let image = CIImage(cvPixelBuffer: packet.frame.pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB()) else { throw PipelineError.invalid("Unable to prepare depth frame.") }
                let geometry = Letterbox(width: width, height: height, size: contract.inputSize)
                let targets: [[String: Any]] = packet.detections.map { detection in
                    let box = geometry.source(detection.box)
                    return ["id": detection.trackID, "box": [box.x1/Float(width), box.y1/Float(height), box.x2/Float(width), box.y2/Float(height)], "coefficients": detection.coefficients]
                }
                let half = packet.prototypes.map { Float16($0) }
                let prototypeData = half.withUnsafeBytes { Data($0) }
                var payload: [String: Any] = ["image": jpeg.base64EncodedString(), "targets": targets,
                    "prototypeShape": [contract.maskChannels, contract.prototypeHeight, contract.prototypeWidth],
                    "prototypes": prototypeData.base64EncodedString(), "inputSize": contract.inputSize]
                if let reference {
                    payload["referenceDepth"] = reference.file.path
                    payload["referenceUnitsPerMetre"] = reference.unitsPerMetre
                }
                var bytes = try JSONSerialization.data(withJSONObject: payload); bytes.append(10)
                try input.write(contentsOf: bytes)
                let response = try readJSON(output)
                if let error = response["error"] as? String { throw PipelineError.invalid(error) }
                func values(_ key: String) -> [Int: Double] {
                    let raw = response[key] as? [String: Double] ?? [:]
                    return Dictionary(uniqueKeysWithValues: raw.compactMap { id, value in Int(id).map { ($0, value) } })
                }
                lock.lock(); let stillActive = generation == ticket; lock.unlock()
                guard stillActive else { return }
                let observation = DistanceResult(received: packet.frame.received, sequence: packet.frame.sequence,
                                                 values: values("distances"), referenceValues: values("referenceDistances"),
                                                 workerSeconds: response["workerSeconds"] as? Double ?? 0)
                measured = observation
                result.set(observation)
                status.set("Mask-based approximate depth · indoor model · uncalibrated")
            } catch {
                lock.lock()
                let stillActive = generation == ticket
                let failedProcess = process
                process = nil; input = nil; output = nil
                lock.unlock()
                if stillActive { result.set(nil); status.set("Distance unavailable: \(error.localizedDescription)") }
                if let failedProcess, failedProcess.isRunning { failedProcess.terminate() }
            }
        }
        return true
    }
    private func launch(ticket: Int) throws {
        var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PelagiVex")
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("model/local-depth/model.safetensors").path) {
            root = Bundle.main.bundleURL
            for _ in 0..<6 { root.deleteLastPathComponent() }
        }
        let python = root.appendingPathComponent(".venv-model/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let script = Bundle.main.url(forResource: "depth_worker", withExtension: "py") else {
            throw PipelineError.invalid("Local depth environment not found.")
        }
        status.set("Loading indoor depth model…")
        let task = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        task.executableURL = python; task.arguments = ["-B", script.path, root.path]
        task.standardInput = stdinPipe; task.standardOutput = stdoutPipe; task.standardError = FileHandle.nullDevice
        lock.lock()
        guard generation == ticket else { lock.unlock(); throw PipelineError.invalid("Depth request cancelled.") }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        lock.unlock()
        let response = try readJSON(stdoutPipe.fileHandleForReading)
        guard response["ready"] as? Bool == true else { throw PipelineError.invalid(response["error"] as? String ?? "Depth model failed to load.") }
    }
    private func readJSON(_ handle: FileHandle) throws -> [String: Any] {
        var bytes = Data()
        while bytes.count < 1_000_000 {
            guard let part = try handle.read(upToCount: 1), !part.isEmpty else { throw PipelineError.invalid("Depth worker stopped.") }
            if part[0] == 10 { break }; bytes.append(part)
        }
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw PipelineError.invalid("Invalid depth response.") }
        return value
    }
}
#endif
