#if os(macOS)
import CoreVideo
import PelagiVexCpp

/// A capture-queue-only visual check. Appearance changes guide sampling; they do not measure camera pose.
struct AutoOrbitFrameGate {
    struct Sample {
        fileprivate let signature: [Float]
    }

    enum Verdict {
        case accept(Sample), dark, soft, unchanged, abrupt, unavailable

        var message: String {
            switch self {
            case .accept: return "继续缓慢绕拍，保持物体完整可见。"
            case .dark: return "画面偏暗，请照亮物体。"
            case .soft: return "画面细节不足，请放慢镜头并保持对焦。"
            case .unchanged: return "请继续移动镜头，寻找新的视角。"
            case .abrupt: return "画面变化过大，请移回上一个视角附近，再缓慢移动。"
            case .unavailable: return "暂时无法读取摄像头画面。"
            }
        }
    }

    private final class Storage {
        let handle: OpaquePointer

        init(copying source: Storage? = nil) {
            let allocated = if let source { pvxAutoOrbitClone(source.handle) } else { pvxAutoOrbitCreate() }
            guard let allocated else { fatalError("Could not allocate automatic capture history") }
            handle = allocated
        }

        deinit { pvxAutoOrbitDestroy(handle) }
    }

    private var storage = Storage()

    func evaluate(_ frame: CameraFrame) -> Verdict {
        let pixels = frame.pixels
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return .unavailable }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return .unavailable }

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: Int(PVX_AUTO_ORBIT_SAMPLE_COUNT)) { signature in
            let verdict = pvxAutoOrbitEvaluate(storage.handle, bytes, CVPixelBufferGetWidth(pixels),
                                                CVPixelBufferGetHeight(pixels), CVPixelBufferGetBytesPerRow(pixels),
                                                signature.baseAddress)
            switch verdict {
            case PVXAutoOrbitAccept: return .accept(Sample(signature: Array(signature)))
            case PVXAutoOrbitDark: return .dark
            case PVXAutoOrbitSoft: return .soft
            case PVXAutoOrbitUnchanged: return .unchanged
            case PVXAutoOrbitAbrupt: return .abrupt
            default: return .unavailable
            }
        }
    }

    /// Advance history only after the corresponding image and manifest have been saved successfully.
    mutating func commit(_ sample: Sample) {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(copying: storage) }
        sample.signature.withUnsafeBufferPointer { pvxAutoOrbitCommit(storage.handle, $0.baseAddress) }
    }

    mutating func reset() {
        if isKnownUniquelyReferenced(&storage) { pvxAutoOrbitReset(storage.handle) }
        else { storage = Storage() }
    }
}
#endif
