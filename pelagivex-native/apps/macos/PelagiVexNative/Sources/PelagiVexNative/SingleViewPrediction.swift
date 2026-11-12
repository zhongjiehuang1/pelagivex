#if os(macOS)
import CoreVideo
import Foundation
import PelagiVexCpp
import PelagiVexDepth

enum SingleViewPrediction {
    struct MemoryMesh: Sendable {
        let positions: Data
        let indices: Data
        let vertexCount: Int
        let triangleCount: Int
        let usedDepth: Bool
    }

    struct Report: Codable, Sendable {
        let method: String
        let usedDepth: Bool
        let vertices: Int
        let triangles: Int
        let depthSeconds: Double
        let geometrySeconds: Double
        let exportSeconds: Double
        let metricScaleCalibrated = false
        let hiddenSurfaceInferred = true

        enum CodingKeys: String, CodingKey {
            case method, usedDepth, vertices, triangles, depthSeconds, geometrySeconds, exportSeconds
            case metricScaleCalibrated, hiddenSurfaceInferred
        }
    }

    static func prepareDepth() async {
        _ = bundledDepth?.withUnsafeFileSystemRepresentation { PVPrepareProximity($0) }
    }

    static func write(_ input: SingleViewInput, to url: URL, modelURL: URL? = bundledDepth) async throws -> Report {
        try withMesh(input, modelURL: modelURL) { mesh, depthSeconds, geometrySeconds in
            let exportStarted = ProcessInfo.processInfo.systemUptime
            guard let vertices = UInt32(exactly: mesh.vertexCount),
                  let triangles = UInt32(exactly: mesh.indexCount / 3) else {
                throw Failure(text: "轮廓过小或不完整。请让物体完整出现在画面中央。")
            }
            try Task.checkCancellation()
            let status = url.withUnsafeFileSystemRepresentation {
                PVWriteSingleViewUSDZ($0, mesh.positions, vertices, mesh.triangleIndices, triangles)
            }
            guard status == 0 else { throw Failure(text: "无法写入单视角 USDZ 模型。") }
            return Report(method: mesh.usedDepth == 1 ? "Depth Anything V2 Small + silhouette closure" : "silhouette closure",
                          usedDepth: mesh.usedDepth == 1, vertices: mesh.vertexCount, triangles: Int(triangles),
                          depthSeconds: depthSeconds, geometrySeconds: geometrySeconds,
                          exportSeconds: ProcessInfo.processInfo.systemUptime - exportStarted)
        }
    }

    /// The small live card uses the silhouette closure without queuing depth inference.
    static func liveMesh(_ input: SingleViewInput) throws -> MemoryMesh {
        try withMesh(input, modelURL: nil) { mesh, _, _ in
            guard let positions = mesh.positions, let indices = mesh.triangleIndices else {
                throw Failure(text: "没有可用于建模的物体轮廓。")
            }
            return MemoryMesh(positions: Data(bytes: positions, count: 3 * mesh.vertexCount * MemoryLayout<Float>.stride),
                              indices: Data(bytes: indices, count: mesh.indexCount * MemoryLayout<UInt32>.stride),
                              vertexCount: mesh.vertexCount, triangleCount: mesh.indexCount / 3, usedDepth: mesh.usedDepth == 1)
        }
    }

    private static func withMesh<T>(_ input: SingleViewInput, modelURL: URL?,
                                    use: (PVSingleViewMesh, Double, Double) throws -> T) throws -> T {
        try Task.checkCancellation()
        let bounds = input.bounds
        let clock = ProcessInfo.processInfo
        guard input.width > 0, input.height > 0, input.width <= 256, input.height <= 256,
              input.mask.count == input.width * input.height, bounds.width > 0, bounds.height > 0 else {
            throw Failure(text: "没有可用于建模的物体轮廓。")
        }
        let depthStarted = clock.systemUptime
        var depth = [Float](repeating: 0, count: input.mask.count)
        let estimated = modelURL?.withUnsafeFileSystemRepresentation { path in
            depth.withUnsafeMutableBufferPointer { values in
                PVEstimateProximity(path, Unmanaged.passUnretained(input.pixels).toOpaque(),
                    Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height),
                    Int32(input.width), Int32(input.height), values.baseAddress) == 1
            }
        } ?? false
        let geometryStarted = clock.systemUptime
        try Task.checkCancellation()
        let sampleWidth = bounds.width * CGFloat(CVPixelBufferGetWidth(input.pixels)) / CGFloat(input.width)
        let sampleHeight = bounds.height * CGFloat(CVPixelBufferGetHeight(input.pixels)) / CGFloat(input.height)
        var mesh = PVSingleViewMesh()
        defer { PVSingleViewVolumeFree(&mesh) }
        let built = input.mask.withUnsafeBufferPointer { mask in
            depth.withUnsafeBufferPointer { proximity in
                PVSingleViewVolumeBuild(mask.baseAddress, mask.count, Int32(input.width), Int32(input.height),
                    estimated ? proximity.baseAddress : nil, estimated ? proximity.count : 0,
                    Float(sampleWidth / sampleHeight), &mesh)
            }
        }
        guard built == 1 else {
            throw Failure(text: "轮廓过小或不完整。请让物体完整出现在画面中央。")
        }
        let geometrySeconds = clock.systemUptime - geometryStarted
        try Task.checkCancellation()
        return try use(mesh, geometryStarted - depthStarted, geometrySeconds)
    }

    private static var bundledDepth: URL? {
        Bundle.main.url(forResource: "RelativeDepth", withExtension: "mlmodelc") ??
            Bundle.main.url(forResource: "RelativeDepth", withExtension: "mlpackage")
    }

    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }
}
#endif
