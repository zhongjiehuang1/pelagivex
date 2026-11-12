#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import SwiftUI

/// Opt-in metrics from the real application window. No frames or object labels are written.
final class CamoLiveBenchmark {
    struct LiveOverlayState: Equatable {
        let active: Bool
        var targetID: Int? = nil
        var modelReady = false
        var cardVisible = false
        var cardSlot: Int? = nil
        var cardWidth: Double? = nil
        var cardHeight: Double? = nil
        var modelFieldOfView: Double? = nil
        var zoomFieldOfView: Double? = nil
    }

    static var ambientDepthOverride: Bool? {
        guard CommandLine.arguments.dropFirst().first == "--camo-live-benchmark" else { return nil }
        switch ProcessInfo.processInfo.environment["PELAGIVEX_BENCH_AMBIENT_DEPTH"] {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    private struct Sample: Encodable {
        let seconds: Double
        let captureFPS: Double
        let detectionFPS: Double
        let displayFPS: Double
        let samFPS: Double
        let callbackToGPUP95MS: Double?
        let modelMS: Double?
        let gpuMS: Double?
        let samWorkerMS: Double?
        let samRoundtripMS: Double?
        let samAgeSeconds: Double?
        let fineTargets: Int
        let contourTargets: Int
        let observedTracks: Int
        let retainedTracks: Int
        let observedBoth: Int
        let observedToRetained: Int
        let retainedToObserved: Int
        let newObserved: Int
        let thermalState: Int
        let liveOverlay: LiveOverlaySample?
    }

    private struct LiveOverlaySample: Encodable {
        let active: Bool
        let targetLocked: Bool
        let targetOrdinal: Int?
        let modelReady: Bool
        let cardVisible: Bool
        let cardSlot: Int?
        let cardWidth: Double?
        let cardHeight: Double?
        let modelFieldOfView: Double?
        let zoomFieldOfView: Double?
        let newDisplayAfterModel: Bool
    }

    private struct InteractiveEvent: Encodable {
        let kind: String
        let seconds: Double
        var targetOrdinal: Int?
        var modelReady: Bool?
        var cardVisible: Bool?
        var cardSlot: Int?
        var cardWidth: Double?
        var cardHeight: Double?
        var modelFieldOfView: Double?
        var zoomFieldOfView: Double?
        var valid: Bool?
    }

    private struct LiveOverlayReport: Encodable {
        let firstLockAfterCameraRequestSeconds: Double?
        let firstModelAfterCameraRequestSeconds: Double?
        let firstCardAfterCameraRequestSeconds: Double?
        let lockAcquisitions: Int
        let activeSamples: Int
        let lockedSamples: Int
        let modelReadySamples: Int
        let cardVisibleSamples: Int
        let sampledNewDisplaysWithModel: Int
        let cardSlots: [Int]
        let cardSideChanges: Int
        let cardSizeChanges: Int
        let minimumCardWidth: Double?
        let maximumCardWidth: Double?
        let displayWithModel: Rates?
    }

    private struct Rates: Encodable {
        let median: Double
        let p05: Double
        let fractionAtOrAbove29Point5: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            median = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
            p05 = sorted[Int(Double(sorted.count - 1) * 0.05)]
            fractionAtOrAbove29Point5 = Double(values.filter { $0 >= 29.5 }.count) / Double(values.count)
        }
    }

    private struct Report: Encodable {
        let valid: Bool
        let failure: String?
        let captureDevice: String?
        let frameWidth: Int?
        let frameHeight: Int?
        let performanceProfile: String
        let rendererMode: String
        let ambientDepthEnabled: Bool
        let systemVersion: String
        let processorCount: Int
        let warmupSeconds: Double
        let measurementSeconds: Double
        let capture: Rates?
        let detection: Rates?
        let display: Rates?
        let samSubmissions: Int
        let samCompletions: Int
        let samFailures: Int
        let samCompletionsPerSecond: Double?
        let fineCoverage: Double?
        let liveOverlay: LiveOverlayReport?
        let samples: [Sample]
        let scope = "Live Camo in the production app and GPU renderer, metrics only. FPS and latency are rolling unique-frame meters sampled by the 4 Hz application refresh. Fine coverage counts contours accepted for display by age and geometry gates, not boundary accuracy. Track transitions are sampled ID continuity without identity or object ground truth. Overlay timings start at the camera request. Overlay display counts are sampled Metal completions, and do not measure panel scanout."
    }

    let profile: RecognitionPerformance
    private let output: URL
    private let duration: Double
    private let requireLiveOverlay: Bool
    private let interactive: Bool
    private let started = ProcessInfo.processInfo.systemUptime
    private let warmup = 6.0
    private var cameraName: String?
    private var cameraRequestedAt: Double?
    private var firstDisplayAt: Double?
    private var sampleStartedAt: Double?
    private var initialSAM = RefinementCounts()
    private var samples: [Sample] = []
    private var previousObserved = Set<Int>()
    private var previousRetained = Set<Int>()
    private var overlay = LiveOverlayState(active: false)
    private var firstLockSeconds: Double?
    private var firstModelSeconds: Double?
    private var firstCardSeconds: Double?
    private var lockAcquisitions = 0
    private var previousCardSlot: Int?
    private var cardSlots = Set<Int>()
    private var cardSideChanges = 0
    private var cardSizeChanges = 0
    private var lastSampledModelDisplay: UInt64?
    private var trace: FileHandle?
    private let traceEncoder = JSONEncoder()
    private var traceFailure: String?
    private var overlayEvents = 0
    private var signaledReady = false
    private var targetOrdinals: [Int: Int] = [:]

    static func fromCommandLine() -> CamoLiveBenchmark? {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--camo-live-benchmark" else { return nil }
        let interactive = args.last == "live" &&
            ProcessInfo.processInfo.environment["PELAGIVEX_BENCH_INTERACTIVE"] == "1"
        let maximumSeconds = interactive ? 900.0 : 180.0
        guard (2...5).contains(args.count),
              let seconds = Double(args.count > 2 ? args[2] : "20"), (8...maximumSeconds).contains(seconds),
              let profile = RecognitionPerformance(rawValue: args.count > 3 ? args[3] : "reference"),
              args.count < 5 || args[4] == "live" else {
            fputs("Usage: --camo-live-benchmark <output.json> [seconds 8...180] [reference|efficient] [live]\n", stderr)
            exit(EXIT_FAILURE)
        }
        return CamoLiveBenchmark(output: URL(fileURLWithPath: args[1]), duration: seconds, profile: profile,
                                 requireLiveOverlay: args.count == 5, interactive: interactive)
    }

    @MainActor
    static func runAndExit() -> Never {
        // A CLI launch may not receive the Launch Services event that creates a
        // SwiftUI WindowGroup window. Host the same production view explicitly.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "PelagiVex"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: ContentView(openWorkbench: fromCommandLine()?.requireLiveOverlay != true))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(window) { app.run() }
        exit(EXIT_FAILURE)
    }

    private init(output: URL, duration: Double, profile: RecognitionPerformance, requireLiveOverlay: Bool, interactive: Bool) {
        self.output = output
        self.duration = duration
        self.profile = profile
        self.requireLiveOverlay = requireLiveOverlay
        self.interactive = interactive && requireLiveOverlay
    }

    private func writeEvent(_ event: InteractiveEvent) {
        guard let trace, traceFailure == nil else { return }
        do {
            var line = try traceEncoder.encode(event)
            line.append(0x0A)
            try trace.write(contentsOf: line)
        } catch {
            traceFailure = "Could not write interactive benchmark events: \(error.localizedDescription)"
        }
    }

    private func ordinal(for targetID: Int?) -> Int? {
        guard interactive, let targetID else { return nil }
        if let ordinal = targetOrdinals[targetID] { return ordinal }
        let ordinal = targetOrdinals.count + 1
        targetOrdinals[targetID] = ordinal
        return ordinal
    }

    private func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func event(_ kind: String, state: LiveOverlayState, seconds: Double) -> InteractiveEvent {
        let slot = visibleSlot(for: state)
        return InteractiveEvent(kind: kind, seconds: seconds, targetOrdinal: ordinal(for: state.targetID),
            modelReady: state.modelReady, cardVisible: slot != nil, cardSlot: slot,
            cardWidth: slot == nil ? nil : finite(state.cardWidth),
            cardHeight: slot == nil ? nil : finite(state.cardHeight),
            modelFieldOfView: slot == nil ? nil : finite(state.modelFieldOfView),
            zoomFieldOfView: finite(state.zoomFieldOfView))
    }

    /// Called on the main queue as the production overlay reports its visible state.
    func observeLiveOverlay(_ state: LiveOverlayState) {
        guard requireLiveOverlay, let requested = cameraRequestedAt else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - requested)
        if state.active, let targetID = state.targetID {
            if firstLockSeconds == nil { firstLockSeconds = elapsed }
            if !overlay.active || overlay.targetID != targetID { lockAcquisitions += 1 }
            if state.modelReady && firstModelSeconds == nil { firstModelSeconds = elapsed }
            if state.modelReady && state.cardVisible && firstCardSeconds == nil { firstCardSeconds = elapsed }
        }
        let slot = visibleSlot(for: state)
        if let slot {
            cardSlots.insert(slot)
            if let previousCardSlot, previousCardSlot != slot, overlay.targetID == state.targetID {
                cardSideChanges += 1
            }
            if sampleStartedAt != nil, previousCardSlot != nil, overlay.targetID == state.targetID,
               let previousWidth = overlay.cardWidth, let width = state.cardWidth,
               abs(width - previousWidth) > 0.5 {
                cardSizeChanges += 1
            }
        }
        previousCardSlot = slot
        if interactive, state != overlay, overlayEvents < 2048 {
            writeEvent(event("overlay", state: state, seconds: elapsed))
            overlayEvents += 1
            if overlayEvents == 2048 { writeEvent(.init(kind: "trace-limit", seconds: elapsed)) }
        }
        overlay = state
    }

    private func visibleSlot(for state: LiveOverlayState) -> Int? {
        guard state.active, state.targetID != nil, state.modelReady, state.cardVisible,
              let slot = state.cardSlot, (0...3).contains(slot) else { return nil }
        return slot
    }

    private func overlaySample(sequence: UInt64?, freshDisplay: Bool) -> LiveOverlaySample? {
        guard requireLiveOverlay else { return nil }
        let locked = overlay.active && overlay.targetID != nil
        let ready = locked && overlay.modelReady
        let visible = ready && overlay.cardVisible
        var advanced = false
        if visible, freshDisplay, let sequence, sequence != lastSampledModelDisplay {
            lastSampledModelDisplay = sequence
            advanced = true
        }
        return LiveOverlaySample(active: overlay.active, targetLocked: locked, targetOrdinal: ordinal(for: overlay.targetID),
                                 modelReady: ready, cardVisible: visible,
                                 cardSlot: visibleSlot(for: overlay), cardWidth: visible ? finite(overlay.cardWidth) : nil,
                                 cardHeight: visible ? finite(overlay.cardHeight) : nil,
                                 modelFieldOfView: visible ? finite(overlay.modelFieldOfView) : nil,
                                 zoomFieldOfView: finite(overlay.zoomFieldOfView),
                                 newDisplayAfterModel: advanced)
    }

    private func overlayReport() -> LiveOverlayReport? {
        guard requireLiveOverlay else { return nil }
        let states = samples.compactMap(\.liveOverlay)
        let displayWithModel = samples.filter { $0.liveOverlay?.cardVisible == true }.map(\.displayFPS)
        let widths = states.compactMap(\.cardWidth)
        return LiveOverlayReport(firstLockAfterCameraRequestSeconds: firstLockSeconds,
                                 firstModelAfterCameraRequestSeconds: firstModelSeconds,
                                 firstCardAfterCameraRequestSeconds: firstCardSeconds,
                                 lockAcquisitions: lockAcquisitions,
                                 activeSamples: states.filter(\.active).count,
                                 lockedSamples: states.filter(\.targetLocked).count,
                                 modelReadySamples: states.filter(\.modelReady).count,
                                 cardVisibleSamples: states.filter(\.cardVisible).count,
                                 sampledNewDisplaysWithModel: states.filter(\.newDisplayAfterModel).count,
                                 cardSlots: cardSlots.sorted(), cardSideChanges: cardSideChanges,
                                 cardSizeChanges: cardSizeChanges, minimumCardWidth: widths.min(), maximumCardWidth: widths.max(),
                                 displayWithModel: displayWithModel.isEmpty ? nil : Rates(displayWithModel))
    }

    func tick(_ controller: AppController, at now: Double) {
        if interactive, trace == nil, traceFailure == nil {
            let traceURL = output.appendingPathExtension("events.jsonl")
            do {
                try Data().write(to: traceURL, options: .withoutOverwriting)
                trace = try FileHandle(forWritingTo: traceURL)
            } catch {
                traceFailure = "Could not create interactive benchmark events: \(error.localizedDescription)"
            }
        }
        if let traceFailure { finish(controller, at: now, failure: traceFailure) }
        if interactive, FileManager.default.fileExists(atPath: output.appendingPathExtension("finish").path) {
            finish(controller, at: now, failure: nil)
        }
        if let problem = controller.pipeline.contourRefiner.failure.get() {
            finish(controller, at: now, failure: "SAM failed: \(problem)")
        }
        if !controller.error.isEmpty {
            finish(controller, at: now, failure: controller.error)
        }
        if cameraRequestedAt == nil {
            if now - started >= 75 { finish(controller, at: now, failure: "The model did not finish loading.") }
            guard !controller.loading else { return }
            guard controller.classCount > 0, controller.performanceProfile == profile else {
                finish(controller, at: now, failure: "The requested recognition model is unavailable.")
            }
            let matches = controller.cameras.filter { $0.localizedName.localizedCaseInsensitiveContains("Camo") }
            guard let camo = matches.first(where: { $0.localizedName == "Camo Camera" }) ??
                    (matches.count == 1 ? matches.first : nil) else {
                finish(controller, at: now, failure: "Camo Camera is unavailable or ambiguous.")
            }
            cameraName = camo.localizedName
            cameraRequestedAt = now
            controller.start(deviceID: camo.uniqueID, liveView: requireLiveOverlay)
            return
        }
        guard controller.running, controller.showFineOutlines, controller.refineBoundaries else {
            finish(controller, at: now, failure: "The camera or fine contour mode was stopped.")
        }
        if firstDisplayAt == nil {
            if controller.telemetry.displayFPS != nil {
                firstDisplayAt = now
                if interactive { writeEvent(.init(kind: "camera-started", seconds: now - (cameraRequestedAt ?? now))) }
            } else if now - (cameraRequestedAt ?? now) >= 25 {
                finish(controller, at: now, failure: "Camo did not produce rendered frames.")
            }
            return
        }
        if sampleStartedAt == nil {
            guard now - (firstDisplayAt ?? now) >= warmup else { return }
            sampleStartedAt = now
            initialSAM = controller.pipeline.contourRefiner.counts.get() ?? RefinementCounts()
            if interactive { writeEvent(.init(kind: "warm", seconds: now - (cameraRequestedAt ?? now))) }
        }
        guard let sampleStartedAt else { return }
        let telemetry = controller.telemetry
        let tracks = controller.objects
        let observed = Set(tracks.filter(\.isObserved).map(\.id))
        let retained = Set(tracks.filter { !$0.isObserved }.map(\.id))
        let refinement = controller.pipeline.contourRefiner.result.get()
        let freshDisplay = (telemetry.frameAgeSeconds ?? .infinity) < 0.75
        if interactive, !signaledReady, freshDisplay, (telemetry.fineCount ?? 0) > 0,
           (controller.pipeline.contourRefiner.counts.get()?.completed ?? 0) > 0,
           visibleSlot(for: overlay) != nil, finite(overlay.modelFieldOfView) != nil {
            signaledReady = true
            writeEvent(event("ready", state: overlay, seconds: now - (cameraRequestedAt ?? now)))
        }
        let liveOverlay = overlaySample(sequence: controller.renderer?.measurements.get()?.sequence, freshDisplay: freshDisplay)
        samples.append(Sample(seconds: now - sampleStartedAt, captureFPS: telemetry.captureFPS ?? 0,
            detectionFPS: telemetry.detectionFPS ?? 0, displayFPS: freshDisplay ? telemetry.displayFPS ?? 0 : 0,
            samFPS: telemetry.samFPS ?? 0, callbackToGPUP95MS: telemetry.latencyP95MS,
            modelMS: telemetry.modelMS, gpuMS: telemetry.gpuMS,
            samWorkerMS: telemetry.samWorkerMS, samRoundtripMS: refinement?.roundtripMS,
            samAgeSeconds: telemetry.samAgeSeconds, fineTargets: freshDisplay ? telemetry.fineCount ?? 0 : 0,
            contourTargets: freshDisplay ? telemetry.totalContourCount ?? 0 : 0,
            observedTracks: observed.count, retainedTracks: retained.count,
            observedBoth: observed.intersection(previousObserved).count,
            observedToRetained: retained.intersection(previousObserved).count,
            retainedToObserved: observed.intersection(previousRetained).count,
            newObserved: observed.subtracting(previousObserved).subtracting(previousRetained).count,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue, liveOverlay: liveOverlay))
        previousObserved = observed
        previousRetained = retained
        if now - sampleStartedAt >= duration { finish(controller, at: now, failure: nil) }
    }

    private func finish(_ controller: AppController, at now: Double, failure: String?) -> Never {
        let counts = controller.pipeline.contourRefiner.counts.get() ?? RefinementCounts()
        let completions = max(0, counts.completed - initialSAM.completed)
        let attempts = max(0, counts.submitted - initialSAM.submitted)
        let failures = max(0, counts.failed - initialSAM.failed)
        let elapsed = sampleStartedAt.map { max(0, now - $0) } ?? 0
        let totalContours = samples.reduce(0) { $0 + $1.contourTargets }
        let fineContours = samples.reduce(0) { $0 + $1.fineTargets }
        let coverage = totalContours > 0 ? Double(fineContours) / Double(totalContours) : nil
        let liveOverlay = overlayReport()
        let overlayProblem: String?
        if let liveOverlay, liveOverlay.firstLockAfterCameraRequestSeconds == nil {
            overlayProblem = "The live view did not lock an object automatically."
        } else if let liveOverlay, liveOverlay.firstModelAfterCameraRequestSeconds == nil {
            overlayProblem = "The live view did not build a model for the locked object."
        } else if let liveOverlay, liveOverlay.sampledNewDisplaysWithModel < 2 {
            overlayProblem = "The live view did not show a model card across two sampled camera display updates."
        } else {
            overlayProblem = nil
        }
        let samProblem = completions == 0 || fineContours == 0 ?
            "The live measurement had no successful SAM refresh with fine contours visible." : nil
        let problem = failure ?? samProblem ?? overlayProblem
        let telemetry = controller.telemetry
        let report = Report(valid: problem == nil, failure: problem, captureDevice: cameraName,
            frameWidth: telemetry.frameWidth, frameHeight: telemetry.frameHeight,
            performanceProfile: profile.rawValue,
            rendererMode: ProcessInfo.processInfo.environment["PELAGIVEX_RENDER_BASELINE"] == "1" ? "baseline" : "optimized",
            ambientDepthEnabled: controller.pipeline.ambientDepthEnabled.get() ?? true,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            warmupSeconds: warmup, measurementSeconds: elapsed,
            capture: samples.isEmpty ? nil : Rates(samples.map(\.captureFPS)),
            detection: samples.isEmpty ? nil : Rates(samples.map(\.detectionFPS)),
            display: samples.isEmpty ? nil : Rates(samples.map(\.displayFPS)),
            samSubmissions: attempts, samCompletions: completions, samFailures: failures,
            samCompletionsPerSecond: elapsed > 0 ? Double(completions) / elapsed : nil,
            fineCoverage: coverage, liveOverlay: liveOverlay, samples: samples)
        controller.stop()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .withoutOverwriting)
            print("Camo live benchmark: \(output.path)")
        } catch {
            writeEvent(.init(kind: "finished", seconds: now - (cameraRequestedAt ?? now), valid: false))
            fputs("Camo benchmark could not write its report: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
        writeEvent(.init(kind: "finished", seconds: now - (cameraRequestedAt ?? now), valid: problem == nil))
        if let problem { fputs("\(problem)\n", stderr) }
        exit(problem == nil ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
#endif
