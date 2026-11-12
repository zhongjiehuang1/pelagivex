#if os(macOS)
import PelagiVexCpp
import SwiftUI
import VisionCore

struct LiveOverlayTarget: Equatable {
    let trackID: Int
    let name: String
    let confidence: Float
    /// Normalized source coordinates, unmirrored, with a top-left origin.
    let rect: CGRect
}

struct LiveOverlayPlacementTelemetry: Equatable {
    let visible: Bool
    let quadrant: Int?
    var width: Double? = nil
    var height: Double? = nil
}

struct LiveCameraOverlay<Wireframe: View>: View {
    let frameSize: CGSize
    let mirrored: Bool
    let isLive: Bool
    let target: LiveOverlayTarget?
    let targetObserved: Bool
    let obstacles: [CGRect]
    let modelReady: Bool
    let onPlacement: (LiveOverlayPlacementTelemetry) -> Void
    private let wireframe: Wireframe

    @State private var memory: PlacementMemory?
    @State private var revealed: CardCandidate?
    @State private var previouslyRevealedTrackID: Int?

    private struct CardCandidate: Equatable {
        let trackID: Int
        let rect: CGRect
        let corner: Int
    }

    private struct PlacementMemory: Equatable {
        let trackID: Int
        let native: PVLivePlacementState

        static func == (lhs: Self, rhs: Self) -> Bool {
            let a = lhs.native, b = rhs.native
            return lhs.trackID == rhs.trackID && a.horizontalSide == b.horizontalSide &&
                a.verticalSide == b.verticalSide && a.hasPosition == b.hasPosition &&
                a.cardX == b.cardX && a.cardY == b.cardY
        }
    }

    init(frameSize: CGSize, mirrored: Bool, isLive: Bool, target: LiveOverlayTarget?, targetObserved: Bool, obstacles: [CGRect],
         modelReady: Bool,
         onPlacement: @escaping (LiveOverlayPlacementTelemetry) -> Void = { _ in },
         @ViewBuilder wireframe: () -> Wireframe) {
        self.frameSize = frameSize
        self.mirrored = mirrored
        self.isLive = isLive
        self.target = target
        self.targetObserved = targetObserved
        self.obstacles = obstacles
        self.modelReady = modelReady
        self.onPlacement = onPlacement
        self.wireframe = wireframe()
    }

    var body: some View {
        GeometryReader { geometry in
            let camera = FocusRegion.imageRect(view: geometry.size, image: frameSize)
            let observed = isLive ? target : nil
            let targetRect = observed.flatMap { project($0.rect, in: camera) }
            let layout = placement(for: observed, targetRect: targetRect, camera: camera)
            let candidate: CardCandidate? = {
                guard modelReady, let observed, let rect = layout.rect, let corner = layout.corner else { return nil }
                return CardCandidate(trackID: observed.trackID, rect: rect, corner: corner)
            }()
            let cardRect = candidate == revealed ? candidate?.rect : nil
            let telemetry = LiveOverlayPlacementTelemetry(
                visible: cardRect != nil, quadrant: cardRect == nil ? nil : layout.corner,
                width: cardRect.map { Double($0.width) }, height: cardRect.map { Double($0.height) })

            ZStack(alignment: .topLeading) {
                if targetObserved, let targetRect {
                    leader(for: targetRect, card: cardRect)
                    if let observed, let label = labelRect(observed.name, target: targetRect, card: cardRect, camera: camera) {
                        targetLabel(observed)
                            .frame(width: label.width, height: label.height)
                            .position(x: label.midX, y: label.midY)
                            .allowsHitTesting(false)
                    }
                }
                if let cardRect {
                    card
                        .frame(width: cardRect.width, height: cardRect.height)
                        .position(x: cardRect.midX, y: cardRect.midY)
                        // A straight slide between corners could cross the tracked object.
                        .transaction { $0.animation = nil }
                }
            }
            .onChange(of: layout.memory, initial: true) { _, next in
                if let next, memory != next { memory = next }
            }
            .onChange(of: telemetry, initial: true) { _, value in onPlacement(value) }
            .task(id: candidate) {
                revealed = nil
                guard let candidate else { return }
                // Hide immediately when clearance disappears. Require a stable
                // placement before mounting the card again to avoid one-frame flashes.
                if previouslyRevealedTrackID == candidate.trackID {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                revealed = candidate
                previouslyRevealedTrackID = candidate.trackID
            }
        }
        .onDisappear { onPlacement(LiveOverlayPlacementTelemetry(visible: false, quadrant: nil)) }
    }

    private func targetLabel(_ target: LiveOverlayTarget) -> some View {
        let percentage = target.confidence.isFinite ? min(100, max(0, Double(target.confidence) * 100)) : 0
        return HStack(spacing: 8) {
            Text(target.name).font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(String(format: "%.0f%%", percentage))
                .font(ConsoleStyle.mono(size: 11, weight: .medium))
                .fixedSize()
        }
        .foregroundStyle(ConsoleStyle.text)
        .shadow(color: .black, radius: 2, x: 0, y: 1)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [ConsoleStyle.raised.opacity(0.93), ConsoleStyle.background.opacity(0.91)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                var grid = Path()
                for x in stride(from: CGFloat(12), to: size.width, by: 20) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(12), to: size.height, by: 20) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(ConsoleStyle.cyan.opacity(0.095)), lineWidth: 0.5)
            }.allowsHitTesting(false).accessibilityHidden(true)
            wireframe.padding(.top, 18)
            Text("预测 3D")
                .font(ConsoleStyle.mono(size: 11, weight: .semibold))
                .foregroundStyle(ConsoleStyle.text)
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityLabel("单视角预测三维线框")
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(ConsoleStyle.cyan.opacity(0.52), lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)
    }

    private func leader(for target: CGRect, card: CGRect?) -> some View {
        Canvas { context, _ in
            let anchor = card.map { edge(of: target, toward: CGPoint(x: $0.midX, y: $0.midY)) }
                ?? CGPoint(x: target.midX, y: target.minY)
            if let card {
                let tip = edge(of: card, toward: anchor)
                let line = Path { path in path.move(to: anchor); path.addLine(to: tip) }
                context.stroke(line, with: .color(ConsoleStyle.cyan.opacity(0.79)), lineWidth: 1)
            }
            let ring = CGRect(x: anchor.x - 6, y: anchor.y - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: ring), with: .color(ConsoleStyle.cyan.opacity(0.21)))
            context.fill(Path(ellipseIn: ring.insetBy(dx: 3, dy: 3)), with: .color(ConsoleStyle.cyan))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func edge(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        let xScale = dx == 0 ? CGFloat.infinity : rect.width / 2 / abs(dx)
        let yScale = dy == 0 ? CGFloat.infinity : rect.height / 2 / abs(dy)
        let scale = min(xScale, yScale)
        guard scale.isFinite else { return CGPoint(x: rect.midX, y: rect.midY) }
        return CGPoint(x: rect.midX + scale * dx, y: rect.midY + scale * dy)
    }

    private func labelRect(_ name: String, target: CGRect, card: CGRect?, camera: CGRect) -> CGRect? {
        let safe = CGRect(x: camera.minX + 10, y: camera.minY + 44,
                          width: camera.width - 20, height: camera.height - 54)
        let width = min(232, max(98, CGFloat(name.count) * 8 + 54), safe.width)
        let height: CGFloat = 27
        guard width >= 82, safe.height >= height else { return nil }
        let top = max(safe.minY, min(safe.maxY - height, target.minY + 8))
        let center = max(safe.minX, min(safe.maxX - width, target.midX - width / 2))
        let origins = [
            CGPoint(x: target.maxX + 8, y: top),
            CGPoint(x: target.minX - width - 8, y: top),
            CGPoint(x: center, y: target.minY - height - 8),
            CGPoint(x: center, y: target.maxY + 8)
        ]
        return origins.map { CGRect(origin: $0, size: CGSize(width: width, height: height)) }
            .first { safe.contains($0) && !$0.intersects(target) && !(card?.intersects($0) ?? false) }
    }

    private func project(_ box: CGRect, in image: CGRect) -> CGRect? {
        guard !image.isEmpty, !box.isNull, !box.isEmpty,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return nil }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let x = mirrored ? 1 - clipped.maxX : clipped.minX
        return CGRect(x: image.minX + x * image.width, y: image.minY + clipped.minY * image.height,
                      width: clipped.width * image.width, height: clipped.height * image.height)
    }

    private func placement(for target: LiveOverlayTarget?, targetRect: CGRect?, camera: CGRect)
        -> (rect: CGRect?, corner: Int?, memory: PlacementMemory?) {
        guard let target, let targetRect else { return (nil, nil, nil) }
        var state = memory.flatMap { $0.trackID == target.trackID ? $0.native : nil }
            ?? PVLivePlacementState(horizontalSide: 0, verticalSide: 0, hasPosition: 0, cardX: 0, cardY: 0)
        let objects = obstacles.compactMap { project($0, in: camera) }.map(nativeRect)
        let place = objects.withUnsafeBufferPointer {
            PVPlaceLiveModel(&state, nativeRect(camera), nativeRect(targetRect), $0.baseAddress, $0.count)
        }
        let next = PlacementMemory(trackID: target.trackID, native: state)
        guard place.corner >= 0 else { return (nil, nil, next) }
        let box = place.rect
        return (CGRect(x: box.x, y: box.y, width: box.width, height: box.height), Int(place.corner), next)
    }

    private func nativeRect(_ rect: CGRect) -> PVLiveRect {
        PVLiveRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
#endif
