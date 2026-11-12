#if os(macOS)
import CoreVideo
import SwiftUI

/// Tracks a single automatically selected identity using only displayed analysis frames.
/// Session state is read and written on the main queue; pixel sampling runs on a worker.
final class TargetScanSession {
    private struct Observation {
        let firstSeen: Double
        let lastSeen: Double
        let center: CGPoint
        let name: String
        let count: Int
        let speed: Double?

        init(row: ObjectRow, box: CGRect, time: Double, imageSize: CGSize, previous: Observation?, maximumGap: Double) {
            name = row.name
            center = CGPoint(x: box.midX, y: box.midY)
            lastSeen = time
            if let previous, previous.name == name, time > previous.lastSeen, time - previous.lastSeen <= maximumGap {
                firstSeen = previous.firstSeen
                count = previous.count + 1
                let dx = (center.x - previous.center.x) * imageSize.width
                let dy = (center.y - previous.center.y) * imageSize.height
                let displacement = hypot(dx, dy) / hypot(imageSize.width, imageSize.height)
                let measured = 100 * displacement / (time - previous.lastSeen)
                speed = previous.speed.map { $0 * 0.65 + measured * 0.35 } ?? measured
            } else {
                firstSeen = time
                count = 1
                speed = nil
            }
        }

        var stable: Bool { count >= 3 && lastSeen - firstSeen >= 0.4 }
    }

    private(set) var isActive = false
    private let worker = DispatchQueue(label: "pelagivex.target-evidence", qos: .utility)
    private var sampling = false
    private var evidence: TargetScanEvidence?
    private var lastSample = -Double.infinity
    private var revision = 0
    private var target: ObjectRow?
    private var lockedAt = 0.0
    private var scanSamples = 0
    private var lostAt: Double?
    private var shuffleRequested = false
    private var observations: [Int: Observation] = [:]
    private var previousSequence: UInt64?
    private var previousSize: CGSize?
    private let imageBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let sceneLabels: Set<String> = ["background", "darkness", "scene", "room"]

    private(set) var aimedSelection = false

    func start(aimed: Bool = false) { isActive = true; aimedSelection = aimed; reset() }
    func stop() { isActive = false; reset() }
    func shuffle() { shuffleRequested = true }

    func reset() {
        target = nil
        lostAt = nil
        shuffleRequested = false
        observations = [:]
        previousSequence = nil
        previousSize = nil
        invalidateEvidence()
    }

    func update(rows: [ObjectRow], packet: Packet?, distance: DistanceResult?, now: Double) -> TargetScanPresentation {
        guard isActive else { return TargetScanPresentation(phase: .idle) }
        guard let packet, now - packet.frame.received <= (packet.textGuided ? 5 : 0.75) else {
            observations = [:]
            previousSequence = nil
            return missing(now: now)
        }
        let imageSize = CGSize(width: CVPixelBufferGetWidth(packet.frame.pixels), height: CVPixelBufferGetHeight(packet.frame.pixels))
        if let previousSize, previousSize != imageSize { reset() }
        previousSize = imageSize
        let visible = rows.filter { row in
            let box = row.sourceBox.intersection(imageBounds)
            return row.isObserved && !box.isEmpty && box.width * box.height < 0.85
                && box.width * imageSize.width >= 16 && box.height * imageSize.height >= 16
                && (packet.textGuided || !sceneLabels.contains(row.name.lowercased()))
                && (!aimedSelection || isAimed(box))
        }
        let isNewFrame = previousSequence != packet.frame.sequence
        if isNewFrame {
            var next: [Int: Observation] = [:]
            for row in visible {
                next[row.id] = Observation(row: row, box: row.sourceBox.intersection(imageBounds), time: packet.frame.received,
                                           imageSize: imageSize, previous: observations[row.id], maximumGap: packet.textGuided ? 5 : 0.75)
            }
            observations = next
            previousSequence = packet.frame.sequence
        }

        let eligible = visible.filter { $0.confidence >= 0.4 && observations[$0.id]?.stable == true }
        let current = visible.first { $0.id == target?.id && $0.name == target?.name }
        let alternatives = eligible.filter { $0.id != target?.id }
        if shuffleRequested, let replacement = alternatives.randomElement() {
            lock(replacement, at: packet.frame.received)
        } else if let current {
            if lostAt != nil { lock(current, at: packet.frame.received) }
            target = current
            shuffleRequested = false
        } else {
            if target != nil, lostAt == nil { _ = missing(now: now) }
            if let lostAt, now - lostAt < 1.5 { return missing(now: now) }
            guard let next = pick(alternatives) ?? pick(eligible) else { return missing(now: now) }
            lock(next, at: packet.frame.received)
        }

        guard let target else { return TargetScanPresentation(phase: .searching) }
        if isNewFrame { scanSamples += 1 }
        sample(packet: packet, id: target.id, now: now)
        let goal = packet.textGuided ? 2 : 4
        let progress = min(1, Double(scanSamples) / Double(goal))
        let sample = evidence.flatMap { result in
            result.trackID == target.id && result.sequence <= packet.frame.sequence && now - result.received <= (packet.textGuided ? 5 : 2.5) ? result : nil
        }
        return TargetScanPresentation(phase: progress < 1 ? .scanning : .tracking, target: target,
            evidence: metrics(target: target, sample: sample, distance: distance, frame: packet, now: now),
            progress: progress, preview: sample?.shape?.preview, canShuffle: eligible.contains { $0.id != target.id },
            singleViewInput: sample?.singleViewInput)
    }

    private func pick(_ candidates: [ObjectRow]) -> ObjectRow? {
        guard aimedSelection else { return candidates.randomElement() }
        let aim = CGPoint(x: 0.5, y: 0.5)
        return candidates.min { first, second in
            let a = first.sourceBox, b = second.sourceBox
            let distanceA = hypot(a.midX - aim.x, a.midY - aim.y)
            let distanceB = hypot(b.midX - aim.x, b.midY - aim.y)
            return distanceA == distanceB ? first.confidence > second.confidence : distanceA < distanceB
        }
    }

    private func isAimed(_ box: CGRect) -> Bool {
        let share = box.width * box.height
        return share >= 0.025 && share <= 0.65 && box.insetBy(dx: -0.025, dy: -0.025).contains(CGPoint(x: 0.5, y: 0.5))
    }

    private func lock(_ row: ObjectRow, at time: Double) {
        target = row
        lockedAt = time
        lostAt = nil
        shuffleRequested = false
        invalidateEvidence()
    }

    private func missing(now: Double) -> TargetScanPresentation {
        guard let target else { return TargetScanPresentation(phase: .searching) }
        if lostAt == nil {
            lostAt = now
            invalidateEvidence()
        }
        return TargetScanPresentation(phase: .lost, target: target)
    }

    private func invalidateEvidence() {
        revision += 1
        evidence = nil
        lastSample = -.infinity
        scanSamples = 0
    }

    private func sample(packet: Packet, id: Int, now: Double) {
        guard !sampling, now - lastSample >= 1, evidence?.sequence != packet.frame.sequence else { return }
        let ticket = revision
        sampling = true
        lastSample = now
        worker.async { [weak self] in
            let measured = TargetScanEvidenceExtractor.extract(from: packet, targetID: id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sampling = false
                if self.revision == ticket { self.evidence = measured }
            }
        }
    }

    private func metrics(target: ObjectRow, sample: TargetScanEvidence?, distance: DistanceResult?, frame: Packet, now: Double) -> [TargetScanMetric] {
        var result: [TargetScanMetric] = []
        if let sample {
            result.append(TargetScanMetric(label: "画面尺寸", value: "\(sample.pixelWidth) × \(sample.pixelHeight)", detail: "目标框 · 原始像素"))
            result.append(TargetScanMetric(label: "画面占比", value: String(format: "%.1f%%", sample.frameShare * 100), detail: "目标框占整帧"))
        }
        if let shape = sample?.shape {
            result.append(TargetScanMetric(label: "轮廓填充", value: String(format: "%.0f%%", shape.fill * 100), detail: shape.source.title))
            if let color = shape.averageColor {
                result.append(TargetScanMetric(label: "采样平均色", value: color.hex, detail: "轮廓内 · 当前光照",
                    swatch: Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)))
            }
        } else if sample != nil {
            result.append(TargetScanMetric(label: "轮廓填充", value: "—", detail: "轮廓采样不足"))
        }
        if let speed = observations[target.id]?.speed, speed.isFinite {
            result.append(TargetScanMetric(label: "画面位移", value: String(format: "%.1f%%/秒", speed), detail: "相对于画面对角线"))
        }
        if !frame.textGuided, let distance, distance.received >= lockedAt,
           distance.sequence <= frame.frame.sequence, now - distance.received <= 4,
           let value = distance.values[target.id], value.isFinite, value > 0 {
            result.append(TargetScanMetric(label: "估计深度", value: String(format: "%.2f m", value), detail: "单目估计 · 未标定"))
        }
        return result
    }
}
#endif
