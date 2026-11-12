#if os(macOS)
import SwiftUI

private extension GuidedOrbitStep {
    var marker: String {
        switch self {
        case .front: "正"
        case .firstSide: "侧"
        case .back: "背"
        case .secondSide: "另"
        case .upper: "高"
        }
    }

    var direction: String {
        switch self {
        case .front: "对准物体正面，开始拍摄后缓慢沿弧线向任意一侧移动。"
        case .firstSide: "沿原来的方向走到第一侧，让镜头仍能看到一部分刚拍过的正面。"
        case .back: "继续绕到物体背面，先带上上一侧面，再逐步把背面拍全。"
        case .secondSide: "沿同一方向拍摄另一侧，再向起点移动，让最后的侧面和正面衔接。"
        case .upper: "把镜头抬高并向下倾斜，沿弧线补拍顶部。画面里保留已拍过的侧面。"
        }
    }
}

struct GuidedOrbitPanel: View {
    let targetName: String
    let step: GuidedOrbitStep
    let counts: [GuidedOrbitStep: Int]
    let isCapturing: Bool
    let isFinishing: Bool
    let canCapture: Bool
    let minimumPhotos: Int
    let message: String
    let onToggleCapture: () -> Void
    let onAdvance: () -> Void
    let onExit: () -> Void
    var onReconstruct: (() -> Void)? = nil
    var isReconstructing = false

    private var total: Int { counts.values.reduce(0, +) }
    private var stepCount: Int { counts[step, default: 0] }
    private var stepReady: Bool { stepCount >= GuidedOrbitStep.recommendedPhotos }
    private var isComplete: Bool {
        total >= minimumPhotos && GuidedOrbitStep.allCases.allSatisfy { counts[$0, default: 0] >= GuidedOrbitStep.recommendedPhotos }
    }

    private var status: String {
        if isReconstructing { return "本机重建中" }
        if isFinishing { return "写入照片" }
        if isCapturing { return "本段拍摄中" }
        if isComplete { return "可提交重建" }
        return "等待拍摄"
    }

    var body: some View {
        ConsolePanel(title: "目标绕拍引导", kicker: "OBJECT ORBIT / 01") {
            VStack(alignment: .leading, spacing: 11) {
                targetHeader
                orbitDiagram
                stepHeader
                note(step.direction)
                note("保持同一个物体静止，每秒保存一张。缓慢移动镜头，让相邻照片保留共同特征并有一点视角变化。")
                angleProgress
                note("每段方向由你确认，进度条按各段实际保存的照片计数。")
                if isComplete, let onReconstruct {
                    Button("生成带标注的模型", action: onReconstruct)
                        .buttonStyle(ConsoleButtonStyle(primary: true))
                        .disabled(isFinishing || isReconstructing)
                }
                if !message.isEmpty { note(message, color: isCapturing ? ConsoleStyle.text : ConsoleStyle.amber) }
                actions
            }
        }
    }

    private var targetHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "scope").foregroundStyle(ConsoleStyle.red).accessibilityHidden(true)
            Text(targetName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            ConsoleTag(status, color: isCapturing ? ConsoleStyle.red : ConsoleStyle.cyan)
        }
        .accessibilityElement(children: .combine)
    }

    private var stepHeader: some View {
        HStack {
            Text("\(step.rawValue + 1)/\(GuidedOrbitStep.allCases.count)")
                .font(ConsoleStyle.mono(size: 11, weight: .semibold))
                .foregroundStyle(ConsoleStyle.red)
            Text(step.title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Text(stepReady ? "本段已存 \(stepCount) 张" : "本段 \(stepCount)/\(GuidedOrbitStep.recommendedPhotos) 张")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(ConsoleStyle.muted).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private var orbitDiagram: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Ellipse().strokeBorder(ConsoleStyle.line, lineWidth: 1)
                    .frame(width: size.width * 0.68, height: size.height * 0.62)
                Ellipse().strokeBorder(ConsoleStyle.red.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: size.width * 0.77, height: size.height * 0.76)
                ForEach(GuidedOrbitStep.allCases) { station in
                    orbitMarker(station).position(point(station, in: size))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(height: 109)
        .background(ConsoleStyle.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ConsoleStyle.line) }
        .accessibilityHidden(true)
    }

    private func orbitMarker(_ station: GuidedOrbitStep) -> some View {
        let current = station == step
        let completed = counts[station, default: 0] >= GuidedOrbitStep.recommendedPhotos
        let tint = current ? ConsoleStyle.red : completed ? ConsoleStyle.cyan : ConsoleStyle.muted
        return Text(station.marker)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(current ? ConsoleStyle.background : tint)
            .frame(width: 25, height: 25)
            .background(current ? tint : ConsoleStyle.panel, in: Circle())
            .overlay { Circle().strokeBorder(tint.opacity(0.65)) }
    }

    private func point(_ station: GuidedOrbitStep, in size: CGSize) -> CGPoint {
        switch station {
        case .front: return CGPoint(x: size.width * 0.50, y: size.height * 0.81)
        case .firstSide: return CGPoint(x: size.width * 0.84, y: size.height * 0.50)
        case .back: return CGPoint(x: size.width * 0.50, y: size.height * 0.19)
        case .secondSide: return CGPoint(x: size.width * 0.16, y: size.height * 0.50)
        case .upper: return CGPoint(x: size.width * 0.50, y: size.height * 0.50)
        }
    }

    private var angleProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("已保存 \(total) 张").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Spacer()
                Text("重建至少 \(minimumPhotos) 张").font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted)
            }
            HStack(spacing: 4) {
                ForEach(GuidedOrbitStep.allCases) { station in
                    let count = counts[station, default: 0]
                    ProgressView(value: Double(min(count, GuidedOrbitStep.recommendedPhotos)),
                                 total: Double(GuidedOrbitStep.recommendedPhotos))
                        .tint(station == step ? ConsoleStyle.red : ConsoleStyle.cyan)
                        .accessibilityLabel(station.title)
                        .accessibilityValue("已保存 \(count) 张，建议至少 \(GuidedOrbitStep.recommendedPhotos) 张")
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(isCapturing ? "暂停采集" : "开始拍摄这一段", action: onToggleCapture)
                .buttonStyle(ConsoleButtonStyle(primary: true, destructive: isCapturing))
                .disabled(isFinishing || isReconstructing || (!isCapturing && !canCapture))
            HStack(spacing: 7) {
                if step.next != nil {
                    Button("确认本段并继续", action: onAdvance)
                        .buttonStyle(ConsoleButtonStyle())
                        .disabled(isFinishing || isReconstructing || !stepReady)
                }
                Button("退出引导", action: onExit)
                    .buttonStyle(ConsoleButtonStyle())
                    .disabled(isFinishing || isReconstructing)
            }
        }
    }

    private func note(_ text: String, color: Color = ConsoleStyle.muted) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(color)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
