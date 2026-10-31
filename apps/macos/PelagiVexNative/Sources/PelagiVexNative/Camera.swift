#if os(macOS)
import AVFoundation
import CoreVideo
import Foundation

struct CameraFrame {
    let pixels: CVPixelBuffer
    let sequence: UInt64
    let received: Double
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "pelagivex.camera.control")
    private let delivery = DispatchQueue(label: "pelagivex.camera.frames", qos: .userInteractive)
    private var sequence: UInt64 = 0
    var onFrame: ((CameraFrame) -> Void)?
    var onState: ((String) -> Void)?

    func start() {
        control.async { [self] in
            do {
                if session.inputs.isEmpty { try configure() }
                session.startRunning()
                if !session.isRunning { throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera could not start."]) }
            } catch { onState?("Camera error: \(error.localizedDescription)") }
        }
    }
    func stop() { control.async { [self] in session.stopRunning() } }

    private func configure() throws {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "No camera found."])
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: delivery)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "Camera", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported camera configuration."])
        }
        session.addInput(input); session.addOutput(output)
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        // Never assume that a 120 Hz display implies a 120 fps camera.
        try device.lockForConfiguration()
        let range = device.activeFormat.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }
        let fps = min(30.0, range?.maxFrameRate ?? 30.0)
        if let range, fps >= range.minFrameRate {
            let duration = CMTime(seconds: 1/fps, preferredTimescale: 1_000_000)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.unlockForConfiguration()
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        onState?("\(device.localizedName) · \(dims.width)×\(dims.height) · requested ≤\(Int(fps)) fps")
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        sequence &+= 1
        onFrame?(CameraFrame(pixels: pixels, sequence: sequence, received: ProcessInfo.processInfo.systemUptime))
    }
}
#endif
