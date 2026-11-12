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

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    func start(deviceID: String) {
        control.async { [self] in
            do {
                try configure(deviceID: deviceID)
                session.startRunning()
                if !session.isRunning { throw NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera could not start."]) }
            } catch { onState?("Camera error: \(error.localizedDescription)") }
        }
    }
    func stop() { control.async { [self] in session.stopRunning() } }

    private func configure(deviceID: String) throws {
        let devices = Self.devices()
        let selected = deviceID == "auto"
            ? (devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first)
            : devices.first { $0.uniqueID == deviceID }
        guard let device = selected else {
            throw NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selected camera is unavailable. Connect it and try again."])
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
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
        // Let the capture session choose a supported frame duration for its selected format.
        // Setting one while the session changes formats can raise an Objective-C exception.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        onState?("\(device.localizedName) · \(dims.width)×\(dims.height) · Automatic camera frame rate")
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        sequence &+= 1
        onFrame?(CameraFrame(pixels: pixels, sequence: sequence, received: ProcessInfo.processInfo.systemUptime))
    }
}
#endif
