#if os(macOS)
/// The latest measured console values. Nil means the stream has no usable sample yet.
struct ConsoleTelemetry {
    var captureFPS: Double?
    var detectionFPS: Double?
    var displayFPS: Double?
    var samFPS: Double?
    var samWorkerMS: Double?
    var samAgeSeconds: Double?
    var frameAgeSeconds: Double?
    var latencyP95MS: Double?
    var modelMS: Double?
    var gpuMS: Double?
    var fineCount: Int?
    var totalContourCount: Int?
    var frameWidth: Int?
    var frameHeight: Int?
    var capturedSource: String?
}
#endif
