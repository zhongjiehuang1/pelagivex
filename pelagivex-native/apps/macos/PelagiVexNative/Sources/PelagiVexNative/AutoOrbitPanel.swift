#if os(macOS)
import SwiftUI

struct AutoOrbitPanel: View {
    enum Phase: Equatable {
        case searching, capturing, paused, reconstructing, failed

        fileprivate var title: String {
            switch self {
            case .searching: "正在锁定目标"
            case .capturing: "正在自动采集"
            case .paused: "采集已暂停"
            case .reconstructing: "正在本机重建"
            case .failed: "任务中断"
            }
        }

        fileprivate var symbol: String {
            switch self {
            case .searching: "scope"
            case .capturing: "camera.aperture"
            case .paused: "pause.circle"
            case .reconstructing: "cube.transparent"
            case .failed: "exclamationmark.circle"
            }
        }

        fileprivate var tint: Color {
            switch self {
            case .searching, .capturing: ConsoleStyle.red
            case .reconstructing: ConsoleStyle.cyan
            case .paused, .failed: ConsoleStyle.amber
            }
        }
    }

    let phase: Phase
    let targetName: String?
    let savedCount: Int
    var goalCount = 30
    let guidance: String
    var quality: String? = nil
    var reconstructionProgress: Double? = nil
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onFinishEarly: (() -> Void)? = nil
    let onCancel: () -> Void
    var onRetry: (() -> Void)? = nil
    var canCancel = true

    var body: some View {
        ConsolePanel(title: "自动建模", kicker: "AUTO ORBIT / AGENT") {
            statusHeader
            phaseTrack

            if phase == .reconstructing {
                reconstructionMeter
            } else if targetName != nil || savedCount > 0 {
                captureMeter
            }

            guidanceNote
            controls
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: phase.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(phase.tint)
                .frame(width: 38, height: 38)
                .background(phase.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(phase.tint.opacity(0.24)) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(phase.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConsoleStyle.text)
                if let targetName {
                    Text(targetName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ConsoleStyle.muted)
                        .lineLimit(1)
                        .help(targetName)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseTrack: some View {
        HStack(spacing: 6) {
            phaseMarker("锁定", number: 1, complete: targetName != nil, current: phase == .searching)
            phaseMarker("采集", number: 2, complete: phase == .reconstructing,
                        current: phase == .capturing || phase == .paused)
            phaseMarker("重建", number: 3, complete: false, current: phase == .reconstructing)
        }
        .accessibilityHidden(true)
    }

    private func phaseMarker(_ title: String, number: Int, complete: Bool, current: Bool) -> some View {
        let tint = current ? phase.tint : complete ? ConsoleStyle.cyan : ConsoleStyle.muted
        return VStack(spacing: 5) {
            Capsule().fill(tint.opacity(current || complete ? 0.85 : 0.20)).frame(height: 2)
            Text("0\(number) \(title)")
                .font(ConsoleStyle.mono(size: 10, weight: current ? .semibold : .regular))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var captureMeter: some View {
        let boundedGoal = max(1, goalCount)
        let boundedCount = max(0, savedCount)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("已保存照片").font(.system(size: 11, weight: .medium)).foregroundStyle(ConsoleStyle.muted)
                Spacer()
                Text("\(boundedCount)")
                    .font(ConsoleStyle.mono(size: 22, weight: .light))
                    .foregroundStyle(ConsoleStyle.cyan)
                    .monospacedDigit()
                Text("/ \(boundedGoal)")
                    .font(ConsoleStyle.mono(size: 11))
                    .foregroundStyle(ConsoleStyle.muted)
            }
            ProgressView(value: Double(min(boundedCount, boundedGoal)), total: Double(boundedGoal))
                .tint(ConsoleStyle.cyan)
                .accessibilityLabel("已保存照片")
                .accessibilityValue("\(boundedCount) 张，参考目标 \(boundedGoal) 张")
        }
    }

    @ViewBuilder private var reconstructionMeter: some View {
        if let progress = reconstructionProgress, progress.isFinite {
            let boundedProgress = min(1, max(0, progress))
            ProgressView(value: boundedProgress) {
                Text("重建进度")
            } currentValueLabel: {
                Text(boundedProgress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .tint(ConsoleStyle.cyan)
        } else {
            ProgressView().controlSize(.small).accessibilityLabel("正在处理重建任务")
        }
    }

    private var guidanceNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(guidance)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ConsoleStyle.text)
                .fixedSize(horizontal: false, vertical: true)
            if phase == .capturing {
                Text("保持同一个物体静止，缓慢绕拍，再抬高镜头补拍顶部。素材达到条件后会自动重建。")
                    .font(.system(size: 10))
                    .foregroundStyle(ConsoleStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quality, !quality.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "waveform").accessibilityHidden(true)
                    Text(quality).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10))
                .foregroundStyle(ConsoleStyle.amber)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsoleStyle.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(phase.tint.opacity(0.2)) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if phase == .capturing {
                    Button("暂停采集", action: onPause).buttonStyle(ConsoleButtonStyle())
                } else if phase == .paused {
                    Button("继续采集", action: onResume).buttonStyle(ConsoleButtonStyle(primary: true))
                } else if phase == .failed, let onRetry {
                    Button("重试重建", action: onRetry).buttonStyle(ConsoleButtonStyle(primary: true))
                }
                Button(phase == .reconstructing ? "取消重建" : "结束任务", action: onCancel)
                    .buttonStyle(ConsoleButtonStyle(destructive: true))
                    .disabled(!canCancel)
            }
            if let onFinishEarly, phase == .capturing || phase == .paused {
                Button("用现有照片重建", action: onFinishEarly).buttonStyle(ConsoleButtonStyle())
            }
        }
    }
}
#endif
