#if os(macOS)
import Foundation
import CoreVideo
import VisionCore

/// SAM evidence from one known source frame. The renderer validates age and association
/// before propagating any of its contours onto a newer, independently detected frame.
struct RefinedFrame {
    let sequence: UInt64
    let received: Double
    let width: Int
    let height: Int
    let detections: [Detection]
    let focusTrackID: Int?
    let mask: InstanceMask
    let representedInstances: Set<UInt8>
    let workerMS: Double
    let roundtripMS: Double
}

struct RefinementCounts {
    var submitted = 0
    var completed = 0
    var failed = 0
}

/// One in-flight request, no backlog. Slow SAM never holds the detector/display queue.
final class AsyncContourRefiner {
    let result = Snapshot<RefinedFrame>()
    let failure = Snapshot<String>()
    let meter = FrameMeter()
    let counts = Snapshot<RefinementCounts>()
    private let worker = OpenVocabularyDetector()
    private let queue = DispatchQueue(label: "pelagivex.contours", qos: .utility)
    private let lock = NSLock()
    private var revision = 0
    private var busy = false
    private var focusTrackID: Int?
    private var hadFocusedObservation = false
    private var lastReset = -Double.infinity
    private var lastSubmitted = -Double.infinity
    private var totals = RefinementCounts()

    func reset() {
        lock.lock()
        revision += 1
        focusTrackID = nil
        hadFocusedObservation = false
        lastReset = ProcessInfo.processInfo.systemUptime
        lastSubmitted = -Double.infinity
        result.set(nil); failure.set(nil); meter.reset()
        totals = RefinementCounts(); counts.set(totals)
        worker.stop()
        lock.unlock()
    }

    func submit(_ packet: Packet, focusedTrackID: Int? = nil) {
        guard packet.contract != nil else { return }
        let focus = focusedTrackID.flatMap { id in packet.detections.first { $0.trackID == id } }
        let missingFocus = focusedTrackID != nil && focus == nil
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if focusTrackID != focusedTrackID || (hadFocusedObservation && missingFocus) {
            // Keep the worker warm, but never reuse a prompt from before a focus change or loss.
            focusTrackID = focusedTrackID
            revision += 1
            lastSubmitted = -Double.infinity
            result.set(nil)
        }
        hadFocusedObservation = focus != nil
        // Inference can finish an older frame after the camera or mode is reset.
        guard !busy, !missingFocus, !packet.detections.isEmpty, failure.get() == nil,
              packet.frame.received > lastReset, now - lastSubmitted >= 0.20 else {
            lock.unlock()
            return
        }
        let request = focus.map { Self.refinementPacket(packet, focus: $0) } ?? packet
        busy = true; lastSubmitted = now
        totals.submitted += 1; counts.set(totals)
        let ticket = revision
        // Use the worker state from admission even if its queue starts much later.
        let workerTicket = worker.currentGeneration()
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            lock.lock(); let valid = ticket == revision; lock.unlock()
            guard valid else { return }
            do {
                let refined = try worker.refine(request, expectedGeneration: workerTicket)
                guard let mask = refined.sourceMask else { return }
                let finished = ProcessInfo.processInfo.systemUptime
                let next = RefinedFrame(sequence: request.frame.sequence, received: request.frame.received,
                    width: CVPixelBufferGetWidth(request.frame.pixels), height: CVPixelBufferGetHeight(request.frame.pixels),
                    detections: request.detections, focusTrackID: focusedTrackID,
                    mask: mask, representedInstances: mask.representedInstances,
                    workerMS: max(0, refined.inferenceMS - request.inferenceMS), roundtripMS: (finished-now)*1000)
                lock.lock()
                if ticket == revision {
                    totals.completed += 1; counts.set(totals)
                    result.set(next)
                    meter.add(sequence: request.frame.sequence, finished: finished, received: request.frame.received)
                }
                lock.unlock()
            } catch {
                lock.lock()
                if ticket == revision { totals.failed += 1; counts.set(totals); failure.set(error.localizedDescription) }
                lock.unlock()
            }
        }
    }

    private static func refinementPacket(_ packet: Packet, focus: Detection) -> Packet {
        // Mask labels index the worker's prompt list, not the detector's full list.
        return Packet(frame: packet.frame, detections: [focus], tracks: packet.tracks, prototypes: [],
                      contract: packet.contract, names: packet.names, preprocessMS: packet.preprocessMS,
                      inferenceMS: packet.inferenceMS, postprocessMS: packet.postprocessMS)
    }
}
#endif
