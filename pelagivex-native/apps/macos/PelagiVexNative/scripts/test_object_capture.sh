#!/usr/bin/env bash
set -euo pipefail

native_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
capture_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pelagivex-capture-test.XXXXXX")
trap 'rm -rf -- "$capture_test_dir"' EXIT

cpp_dir="$native_dir/Sources/PelagiVexCpp"
clang++ -std=c++17 -O2 -dynamiclib -I"$cpp_dir/include" "$cpp_dir/AutoOrbitFrameGate.cpp" \
  -o "$capture_test_dir/libPelagiVexCpp.dylib"
printf 'module PelagiVexCpp { header "%s/include/AutoOrbitFrameGate.h" export * }\n' "$cpp_dir" \
  > "$capture_test_dir/module.modulemap"

swiftc -emit-library -emit-module -module-name VisionCore \
  "$native_dir/Sources/VisionCore/FocusRegion.swift" \
  -emit-module-path "$capture_test_dir/VisionCore.swiftmodule" \
  -o "$capture_test_dir/libVisionCore.dylib"

cat > "$capture_test_dir/Driver.swift" <<'SWIFT'
import Foundation
import CoreVideo
import CoreImage
import ImageIO
import VisionCore

struct CameraFrame {
    let pixels: CVPixelBuffer
    let sequence: UInt64
    let received: Double
}

// Compile the production capture source unchanged while forcing the fixture's
// Core Image conversion onto the CPU.
final class CIContext {
    private let software: CoreImage.CIContext
    init(options: [CIContextOption: Any]) {
        var configured = options
        configured[.useSoftwareRenderer] = true
        software = CoreImage.CIContext(options: configured)
    }
    func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        software.createCGImage(image, from: rect)
    }
}

struct Failure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(text: message) }
}

func frame(sequence: UInt64, time: Double, width: Int = 320, height: Int = 320) throws -> CameraFrame {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw Failure(text: "Could not create fixture frame") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            bytes[offset] = y < height / 2 ? 0 : 255
            bytes[offset + 1] = x < width / 2 ? 0 : 255
            bytes[offset + 2] = x < width / 2 && y < height / 2 ? 255 : 0
            bytes[offset + 3] = 255
        }
    }
    return CameraFrame(pixels: buffer, sequence: sequence, received: time)
}

@MainActor
func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(text: "Timed out waiting for capture") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@main struct CaptureFixture {
    @MainActor static func main() async throws {
        let capture = ObjectScanCapture()
        let sourceSize = CGSize(width: 320, height: 320)
        let region = FocusRegion.selection(start: CGPoint(x: 320, y: 0), end: CGPoint(x: 560, y: 240),
                                           view: CGSize(width: 640, height: 480), image: sourceSize, mirrored: true)
        try require(region == FocusRegion(x: 0, y: 0, width: 0.5, height: 0.5), "Mirrored selection mapped to wrong quadrant")
        var syntheticFolders: [URL] = []
        defer {
            for folder in syntheticFolders { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        }
        func start(guided: Bool = false) throws -> URL {
            capture.start(region: region, source: "PelagiVex synthetic regression", imageSize: sourceSize, guided: guided)
            guard capture.isCapturing, let folder = capture.folderURL else { throw Failure(text: "Could not start fixture scan") }
            syntheticFolders.append(folder)
            return folder
        }

        let folder = try start()
        capture.offer(try frame(sequence: 1, time: 1))
        try await waitFor { capture.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        capture.offer(try frame(sequence: 2, time: 1.5))
        capture.offer(try frame(sequence: 3, time: 2.1))
        let finished = await withCheckedContinuation { continuation in
            capture.finish { continuation.resume(returning: $0) }
        }
        try require(finished == folder && capture.count == 2 && !capture.isFinishing, "Finish did not flush the accepted frame")
        let manifestURL = folder.deletingLastPathComponent().appendingPathComponent("capture.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let records = manifest["frames"] as! [[String: Any]]
        try require(records.compactMap { $0["sequence"] as? Int } == [1, 3], "One-second sampling gate saved the wrong frames")
        try require(manifest["mirrored"] as? Bool == false && manifest["overlays"] as? Bool == false, "Capture provenance was mislabeled")
        let imageURL = folder.appendingPathComponent("view_0001.jpg")
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let center = image.cropping(to: CGRect(x: 80, y: 80, width: 1, height: 1)) else {
            throw Failure(text: "Could not decode the ROI JPEG")
        }
        try require(image.width == 160 && image.height == 160, "ROI JPEG has unexpected dimensions")
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        try require(pixel[0] > 220 && pixel[1] < 35 && pixel[2] < 35, "Saved crop is not the red, unmirrored source quadrant")
        print("PASS mirrored ROI, raw JPEG dimensions and pixel, one-second gate, finish flush")

        let changedFolder = try start()
        capture.offer(try frame(sequence: 4, time: 3, height: 480))
        try await waitFor { !capture.isCapturing }
        let changedFiles = try FileManager.default.contentsOfDirectory(atPath: changedFolder.path)
        try require(capture.count == 0 && changedFiles.isEmpty && capture.message.contains("画幅"), "Source-size change did not stop the scan")
        print("PASS source-size change rejected before saving")

        let failingFolder = try start()
        let blockedManifest = failingFolder.deletingLastPathComponent().appendingPathComponent("capture.json")
        try FileManager.default.createDirectory(at: blockedManifest, withIntermediateDirectories: false)
        capture.offer(try frame(sequence: 5, time: 4))
        try await waitFor { !capture.isCapturing }
        let failedFiles = try FileManager.default.contentsOfDirectory(atPath: failingFolder.path)
        try require(capture.count == 0 && failedFiles.isEmpty, "Failed manifest write left a JPEG behind")
        print("PASS failed manifest write rolls back the JPEG")

        let guidedFolder = try start(guided: true)
        let now = ProcessInfo.processInfo.systemUptime
        capture.offer(try frame(sequence: 6, time: now))
        capture.setGuidedStep(.front)
        capture.offer(try frame(sequence: 7, time: now - 1))
        capture.offer(try frame(sequence: 8, time: now + 1))
        try await waitFor { capture.count == 1 }
        capture.setGuidedStep(nil)
        capture.offer(try frame(sequence: 9, time: now + 2))
        capture.setGuidedStep(.firstSide)
        capture.offer(try frame(sequence: 10, time: now + 3))
        let guidedFinished = await withCheckedContinuation { continuation in
            capture.finish { continuation.resume(returning: $0) }
        }
        try require(guidedFinished == guidedFolder && capture.guidedCounts == [.front: 1, .firstSide: 1],
                    "Paused frames or queued writes changed the guided segment counts")
        let guidedManifestURL = guidedFolder.deletingLastPathComponent().appendingPathComponent("capture.json")
        let guidedManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: guidedManifestURL)) as! [String: Any]
        let guidedRecords = guidedManifest["frames"] as! [[String: Any]]
        try require(guidedRecords.compactMap { $0["sequence"] as? Int } == [8, 10], "Guided scan saved a frame before confirmation")
        try require(guidedRecords.compactMap { $0["guidedStep"] as? String } == ["front", "firstSide"], "Frame lost its original guided segment")
        try require(guidedRecords.allSatisfy { $0["width"] as? Int == 320 && $0["height"] as? Int == 320 },
                    "Guided capture cropped the original frame")
        print("PASS guided capture gate, full-frame saves and original segment labels")
    }
}
SWIFT

swiftc -I "$capture_test_dir" -L "$capture_test_dir" -lVisionCore -lPelagiVexCpp \
  "$native_dir/Sources/PelagiVexNative/GuidedOrbitStep.swift" \
  "$native_dir/Sources/PelagiVexNative/AutoOrbitFrameGate.swift" \
  "$native_dir/Sources/PelagiVexNative/ObjectScanCapture.swift" "$capture_test_dir/Driver.swift" \
  -Xlinker -rpath -Xlinker "$capture_test_dir" -o "$capture_test_dir/test-capture"
"$capture_test_dir/test-capture"
