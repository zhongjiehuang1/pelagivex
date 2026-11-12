#if os(macOS)
import SwiftUI
import VisionCore

enum TargetScanPhase: Equatable {
    case idle, searching, scanning, tracking, lost

    fileprivate var label: String {
        switch self {
        case .idle: "待命"
        case .searching: "待稳定目标"
        case .scanning: "正在扫描"
        case .tracking: "目标已锁定"
        case .lost: "目标丢失"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .idle: ConsoleStyle.muted
        case .searching, .lost: ConsoleStyle.amber
        case .scanning, .tracking: ConsoleStyle.red
        }
    }
}

struct TargetScanPresentation {
    let phase: TargetScanPhase
    var target: ObjectRow? = nil
    var evidence: [TargetScanMetric] = []
    var progress: Double? = nil
    var preview: CGImage? = nil
    var canShuffle = false
    var singleViewInput: SingleViewInput? = nil
}

struct TargetScanMetric: Identifiable {
    let label: String
    let value: String
    var detail: String? = nil
    var swatch: Color? = nil
    var id: String { label }
}

struct TargetScanOverlay: View {
    let scan: TargetScanPresentation
    let imageSize: CGSize
    let mirrored: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if (scan.phase == .scanning || scan.phase == .tracking),
               let target = scan.target, target.isObserved,
               let rect = displayRect(for: target, in: geometry.size) {
                let image = FocusRegion.imageRect(view: geometry.size, image: imageSize)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.addRect(image)
                        path.addRect(rect)
                    }.fill(.black.opacity(0.44), style: FillStyle(eoFill: true))

                    ScanGrid(spacing: 24, color: ConsoleStyle.red.opacity(0.26))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)

                    if scan.phase == .scanning {
                        let animate = !reduceMotion && scan.progress == nil
                        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animate)) { clock in
                            ScanSweep(fraction: sweepPosition(clock.date))
                                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: scan.progress)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                        .offset(x: rect.minX, y: rect.minY)
                    }

                    ScanBrackets()
                        .stroke(.black.opacity(0.72), style: StrokeStyle(lineWidth: 4, lineCap: .square))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    ScanBrackets()
                        .stroke(ConsoleStyle.red, style: StrokeStyle(lineWidth: 2, lineCap: .square))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)

                    HStack(spacing: 5) {
                        Image(systemName: scan.phase == .scanning ? "scope" : "lock.fill")
                        Text(String(format: "目标  %03d", target.id))
                    }
                    .font(ConsoleStyle.mono(size: 10, weight: .semibold))
                    .foregroundStyle(ConsoleStyle.background)
                    .frame(width: 88, height: 20)
                    .background(ConsoleStyle.red, in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: min(rect.minX, max(0, geometry.size.width - 88)),
                            y: rect.minY > 25 ? rect.minY - 23 : min(rect.minY + 4, max(0, geometry.size.height - 20)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func displayRect(for target: ObjectRow, in viewSize: CGSize) -> CGRect? {
        let box = target.sourceBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let region = FocusRegion(x: box.minX, y: box.minY, width: box.width, height: box.height) else { return nil }
        let rect = region.displayRect(view: viewSize, image: imageSize, mirrored: mirrored)
        return rect.isEmpty ? nil : rect
    }

    private func sweepPosition(_ date: Date) -> CGFloat {
        if let progress = scan.progress, progress.isFinite { return min(1, max(0, progress)) }
        if reduceMotion { return 0.5 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
    }
}

struct TargetScanPanel: View {
    let scan: TargetScanPresentation
    let running: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onShuffle: () -> Void
    var onOrbit: (() -> Void)? = nil

    private let columns = [GridItem(.flexible(minimum: 0), spacing: 7),
                           GridItem(.flexible(minimum: 0), spacing: 7)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    header
                    if let target = scan.target, scan.phase == .scanning || scan.phase == .tracking {
                        profile(for: target)
                        if !scan.evidence.isEmpty { metrics }
                    } else {
                        standby
                    }
                }
                .padding(13)
            }
            Rectangle().fill(ConsoleStyle.line).frame(height: 1)
            VStack(spacing: 7) {
                if scan.phase == .tracking, let onOrbit {
                    Button(action: onOrbit) {
                        Label("引导绕拍建模", systemImage: "cube.transparent").frame(maxWidth: .infinity)
                    }.buttonStyle(ConsoleButtonStyle(primary: true))
                }
                actions
            }.padding(13)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TARGET ANALYSIS").font(ConsoleStyle.mono(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(ConsoleStyle.red)
                Spacer(minLength: 4)
                ConsoleTag(scan.phase.label, color: scan.phase.color)
            }
            Text("目标分析台")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("从当前画面随机锁定一个稳定目标")
                .font(.system(size: 11)).foregroundStyle(ConsoleStyle.muted)
        }
    }

    private func profile(for target: ObjectRow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                ConsoleStyle.background
                ScanGrid(spacing: 15, color: ConsoleStyle.red.opacity(0.16)).accessibilityHidden(true)
                if let image = scan.preview {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable().scaledToFit()
                        .padding(15)
                        .accessibilityLabel("目标采样图")
                } else {
                    scanGlyph
                }
                ScanBrackets().stroke(ConsoleStyle.red.opacity(0.75), lineWidth: 1.5)
                    .padding(8).accessibilityHidden(true)
            }
            .frame(height: 112)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Text(String(format: "ID  %03d", target.id))
                    .font(ConsoleStyle.mono(size: 9, weight: .semibold)).foregroundStyle(ConsoleStyle.red)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(ConsoleStyle.background.opacity(0.88))
                    .padding(7)
            }

            Text(target.name)
                .font(.system(size: 20, weight: .semibold)).lineLimit(2)
                .accessibilityAddTraits(.isHeader)

            HStack {
                Text("识别置信度").font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted)
                Spacer()
                Text(String(format: "%.1f%%", target.confidence * 100))
                    .font(ConsoleStyle.mono(size: 12, weight: .semibold)).foregroundStyle(ConsoleStyle.red)
            }.accessibilityElement(children: .combine)

            if scan.phase == .scanning {
                if let progress = scan.progress, progress.isFinite {
                    ProgressView(value: min(1, max(0, progress))).tint(ConsoleStyle.red)
                        .accessibilityLabel("扫描进度")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("正在采样")
                }
            }
        }
        .padding(11)
        .background(ConsoleStyle.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ConsoleStyle.red.opacity(0.32)) }
    }

    private var scanGlyph: some View {
        ZStack {
            Circle().stroke(ConsoleStyle.red.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: 70, height: 70)
            Circle().stroke(ConsoleStyle.red.opacity(0.4), lineWidth: 1)
                .frame(width: 52, height: 52)
            Image(systemName: "scope").font(.system(size: 29, weight: .light))
                .foregroundStyle(ConsoleStyle.red)
        }.accessibilityHidden(true)
    }

    private var standby: some View {
        VStack(spacing: 8) {
            scanGlyph
            Text(scan.phase.label).font(.system(size: 13, weight: .semibold))
            Text(standbyMessage)
                .font(.system(size: 11))
                .foregroundStyle(ConsoleStyle.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(ConsoleStyle.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ConsoleStyle.line) }
    }

    private var standbyMessage: String {
        switch scan.phase {
        case .idle: "开始后，分析台会自动选择画面中的一个目标。"
        case .searching: running ? "请让一个清晰物体连续出现在画面中，并在周围留一点空间。" : "正在连接摄像头，等待可用画面。"
        case .lost:
            if let target = scan.target { "上次锁定 \(target.name)。正在等待重新捕获目标。" }
            else { "正在等待重新捕获目标。" }
        case .scanning, .tracking: "等待目标采样。"
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Rectangle().fill(ConsoleStyle.red).frame(width: 12, height: 1)
                Text("采样特征").font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("LIVE READOUT").font(ConsoleStyle.mono(size: 9)).tracking(0.8).foregroundStyle(ConsoleStyle.muted)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ForEach(scan.evidence) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label).font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted)
                        HStack(spacing: 4) {
                            if let swatch = item.swatch {
                                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 11, height: 11)
                                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.27)) }
                                    .accessibilityHidden(true)
                            }
                            Text(item.value).font(ConsoleStyle.mono(size: 13, weight: .semibold))
                                .lineLimit(2).minimumScaleFactor(0.82)
                        }.foregroundStyle(ConsoleStyle.text)
                        if let detail = item.detail {
                            Text(detail).font(.system(size: 9)).foregroundStyle(ConsoleStyle.muted).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .padding(8)
                    .background(ConsoleStyle.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ConsoleStyle.line) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            if scan.phase == .idle {
                Button(action: onStart) {
                    Label(running ? "开始自动扫描" : "启动并扫描", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(ConsoleButtonStyle(primary: true))
            } else {
                Button(action: onShuffle) {
                    Label("换一个目标", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(ConsoleButtonStyle(primary: true))
                    .disabled(!scan.canShuffle)
                    .help("从其余稳定可见的物体中重新随机选择")
                Button("停止分析", action: onStop)
                    .buttonStyle(ConsoleButtonStyle(destructive: true))
            }
        }
    }
}

private struct ScanBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(19, min(rect.width, rect.height) * 0.24)
        return Path { path in
            path.addLines([CGPoint(x: rect.minX, y: rect.minY + arm), rect.origin,
                           CGPoint(x: rect.minX + arm, y: rect.minY)])
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        }
    }
}

private struct ScanGrid: View {
    let spacing: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, size in
            let path = Path { path in
                for x in stride(from: spacing, to: size.width, by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: spacing, to: size.height, by: spacing) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 0.65)
        }
    }
}

private struct ScanSweep: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let height = min(45, geometry.size.height * 0.32)
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, ConsoleStyle.red.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                Rectangle().fill(ConsoleStyle.red).frame(height: 1.5)
            }
            .offset(y: geometry.size.height * fraction - height)
        }
    }
}
#endif
