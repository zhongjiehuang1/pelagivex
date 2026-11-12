#if os(macOS)
import SwiftUI
import AVFoundation
import VisionCore

private enum InspectorPage: String, CaseIterable {
    case targets = "目标", analysis = "分析", controls = "控制", studio = "3D"

    var symbol: String {
        switch self {
        case .targets: return "scope"
        case .analysis: return "viewfinder"
        case .controls: return "slider.horizontal.3"
        case .studio: return "cube.transparent"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .targets: return "显示目标情报"
        case .analysis: return "显示自动分析台"
        case .controls: return "显示系统控制"
        case .studio: return "显示三维工作室"
        }
    }
}

/// Presentation only: camera, inference, identity and evidence policy remain in AppController.
struct ContentView: View {
    @StateObject private var controller = AppController()
    @StateObject private var reconstruction = ObjectReconstruction()
    @StateObject private var guidedOrbit = GuidedOrbitSession()
    @StateObject private var autoOrbit = AutoOrbitSession()
    private let autoOrbitClock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var orbitEntryError: String?
    @State private var showingModel = false
    @State private var page: InspectorPage = .targets
    @State private var showPrompts = false
    @State private var showDiagnostics = false
    @State private var expandedViewport = false
    @State private var showsWorkbench: Bool

    init(openWorkbench: Bool = false) {
        _showsWorkbench = State(initialValue: openWorkbench)
    }

    private var guidingOrbit: Bool { page == .studio && (guidedOrbit.target != nil || autoOrbit.active) && !showingModel }
    private var canStartAutomaticOrbit: Bool {
        !controller.loading && controller.renderer != nil && reconstruction.isSupported && !reconstruction.isBusy
            && guidedOrbit.target == nil && !controller.objectCapture.isCapturing && !controller.objectCapture.isFinishing
    }

    private var serviceNotice: String? {
        guard controller.running else { return nil }
        if controller.recognitionStatus.contains("unavailable:") { return controller.recognitionStatus }
        if controller.distanceStatus.hasPrefix("Distance unavailable:") { return controller.distanceStatus }
        return nil
    }
    private var contourMode: String {
        if controller.recognitionMode == .text { return "文字找物 / SAM" }
        if !controller.refineBoundaries { return "当前原生分割" }
        if controller.recognitionStatus.hasPrefix("Detailed refinement unavailable:") { return "原生分割 / 细化不可用" }
        return "SAM / 后台细化"
    }

    private var visibleCount: Int { controller.focusedObjects.filter(\.isObserved).count }
    private var missingCount: Int { controller.focusedObjects.count - visibleCount }
    private var live: Bool {
        guard controller.running, controller.error.isEmpty, let age = controller.telemetry.frameAgeSeconds else { return false }
        return age <= (controller.recognitionMode == .fast ? 0.75 : 5)
    }
    private var signalColor: Color {
        !controller.error.isEmpty ? ConsoleStyle.red : live ? ConsoleStyle.cyan : ConsoleStyle.amber
    }
    private var signalLabel: String {
        if !controller.error.isEmpty { return "异常 / ERROR" }
        if controller.loading { return "准备 / LOADING" }
        if !controller.running { return "待命 / STANDBY" }
        if live { return "实时 / LIVE" }
        return controller.telemetry.frameAgeSeconds == nil ? "连接 / CONNECTING" : "画面过期 / STALE"
    }

    var body: some View {
        ZStack {
            if showsWorkbench && !controller.liveCameraMode {
                console
                    .onExitCommand {
                        if !controller.objectCapture.isCapturing && !reconstruction.isBusy && !autoOrbit.active {
                            showsWorkbench = false
                            if controller.running { controller.setLiveCameraMode(true) }
                        }
                    }
            } else {
                LiveCameraView(controller: controller, onWorkbench: {
                    controller.setLiveCameraMode(false)
                    showsWorkbench = true
                })
                .ignoresSafeArea()
            }
        }
        .frame(minWidth: showsWorkbench ? 1120 : 480, minHeight: showsWorkbench ? 740 : 270)
        .background(ConsoleBackground())
        .foregroundStyle(ConsoleStyle.text)
        .tint(ConsoleStyle.red)
        .preferredColorScheme(.dark)
        .onDisappear { autoOrbit.reset(); controller.stop(); reconstruction.cancel() }
        .onReceive(autoOrbitClock) { _ in
            if autoOrbit.active { autoOrbit.tick(controller: controller, reconstruction: reconstruction) }
        }
        .onChange(of: reconstruction.isBusy) { _, busy in controller.reconstructionBusy = busy }
        .onChange(of: reconstruction.state) { _, _ in autoOrbit.reconstructionChanged(reconstruction) }
        .onChange(of: reconstruction.outputURL) { _, url in
            guard url != nil else { return }
            showingModel = true
            if reconstruction.linkedAnalysis != nil { guidedOrbit.reset() }
        }
        .onChange(of: page) { _, next in
            if next != .analysis && autoOrbit.phase != .searching { controller.stopTargetScan() }
            if next != .studio { guidedOrbit.pause(controller.objectCapture) }
        }
        .onChange(of: controller.running) { _, running in
            if !running { guidedOrbit.pause(controller.objectCapture) }
        }
        .onChange(of: controller.liveCameraMode) { _, liveCameraMode in
            if liveCameraMode { showsWorkbench = false }
        }
        .onChange(of: showingModel) { _, visible in if visible { controller.stopTargetScan() } }
        .onChange(of: controller.recognitionMode) { _, mode in
            if mode == .text { showPrompts = true }
        }
        .onChange(of: controller.promptError) { _, error in
            if !error.isEmpty { showPrompts = true }
        }
    }

    private var console: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        viewport.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                        if !expandedViewport && !showingModel {
                            if page != .analysis && !guidingOrbit { pairDeck }
                            telemetryStrip
                        }
                    }
                    inspector.frame(width: geometry.size.width < 1260 ? 310 : 342)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 34)
        }
    }

    private var header: some View {
        HStack(spacing: 15) {
            ConsoleGlyph(size: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("PELAGIVEX").font(.system(size: 23, weight: .semibold, design: .monospaced)).tracking(4)
                HStack(spacing: 9) {
                    Text("视觉感知系统").font(.system(size: 10, weight: .medium))
                    Text("/  PERCEPTION CONSOLE").font(ConsoleStyle.mono(size: 9)).tracking(1.4)
                }.foregroundStyle(ConsoleStyle.muted)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("本机处理").font(.system(size: 11, weight: .medium))
                Text("ON DEVICE").font(ConsoleStyle.mono(size: 9)).foregroundStyle(ConsoleStyle.muted)
            }.foregroundStyle(ConsoleStyle.cyan)
                .padding(.trailing, 10)
            Button {
                if autoOrbit.active { page = .studio }
                else { beginAutomaticOrbit() }
            } label: {
                Label(autoOrbit.active ? "自动建模任务" : "一键建模", systemImage: "cube.transparent")
            }.buttonStyle(ConsoleButtonStyle(primary: true))
                .disabled(!autoOrbit.active && !canStartAutomaticOrbit)
            Rectangle().fill(ConsoleStyle.line).frame(width: 1, height: 28)
            Button {
                if controller.running { controller.stop() } else { showingModel = false; controller.start() }
            } label: {
                Label(controller.running ? "停止采集" : "启动摄像头", systemImage: controller.running ? "stop.fill" : "play.fill")
                    .frame(minWidth: 104)
            }
            .buttonStyle(ConsoleButtonStyle(destructive: controller.running))
            .disabled(controller.loading || controller.reconstructionBusy || controller.renderer == nil)
            .accessibilityLabel(controller.running ? "停止摄像头" : "启动摄像头")
            .keyboardShortcut("r", modifiers: [.command])
            .help("启动或停止摄像头 · ⌘R")
        }.frame(height: 48)
    }

    private var viewport: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("01").font(ConsoleStyle.mono(size: 10)).foregroundStyle(ConsoleStyle.red)
                Text(showingModel ? "空间模型" : guidingOrbit ? "绕拍取景" : page == .analysis ? "目标扫描" : "感知视野")
                    .font(.system(size: 12, weight: .semibold))
                Text(showingModel ? "SPATIAL MODEL" : guidingOrbit ? "GUIDED ORBIT" : page == .analysis ? "TARGET SCANNER" : "VISUAL FIELD")
                    .font(ConsoleStyle.mono(size: 9)).tracking(1.5).foregroundStyle(ConsoleStyle.muted)
                Spacer()
                if reconstruction.outputURL != nil {
                    Button(showingModel ? "返回实况" : "查看 3D") {
                        if !showingModel && controller.running { controller.stop() }
                        showingModel.toggle()
                    }.buttonStyle(ConsoleButtonStyle())
                        .disabled(autoOrbit.active || controller.objectCapture.isCapturing || controller.objectCapture.isFinishing || reconstruction.isBusy)
                }
                if !showingModel && !guidingOrbit {
                    Button(controller.focusSelecting ? "取消框选" : "框选区域") { controller.focusSelecting.toggle() }
                        .buttonStyle(ConsoleButtonStyle())
                        .disabled(!live || controller.objectCapture.isCapturing || reconstruction.isBusy)
                    if controller.focusRegion != nil {
                        Button("全画面") { controller.setFocus(nil) }.buttonStyle(ConsoleButtonStyle())
                            .disabled(controller.objectCapture.isCapturing || reconstruction.isBusy)
                    }
                }
                ConsoleTag(showingModel ? "3D / 本机重建" : signalLabel, color: showingModel ? ConsoleStyle.cyan : signalColor)
                if controller.running && !guidingOrbit && !showingModel &&
                    !controller.objectCapture.isCapturing && !controller.objectCapture.isFinishing {
                    Button { controller.setLiveCameraMode(true) } label: {
                        Image(systemName: "rectangle.inset.filled").font(.system(size: 12))
                    }.buttonStyle(ConsoleButtonStyle()).accessibilityLabel("进入实时大屏")
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                }
                Button { expandedViewport.toggle() } label: {
                    Image(systemName: expandedViewport ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(ConsoleStyle.muted)
                    .accessibilityLabel(expandedViewport ? "显示完整仪表" : "展开视野")
                    .help(showingModel ? "三维模型已使用完整视野" : expandedViewport ? "返回完整仪表" : "展开视野")
                    .disabled(showingModel)
            }.padding(.horizontal, 16).frame(height: 43)
            Rectangle().fill(ConsoleStyle.line).frame(height: 1)
            ZStack {
                // Keep this surface mounted when switching inspector pages or camera states.
                MetalSurface(controller: controller).accessibilityHidden(showingModel)
                if !controller.running {
                    standby.accessibilityHidden(showingModel)
                } else if controller.telemetry.frameAgeSeconds == nil {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small).tint(ConsoleStyle.red)
                        Text("正在建立视觉连接").font(.system(size: 13, weight: .medium))
                        Text("等待第一帧分析结果").font(ConsoleStyle.mono(size: 10)).foregroundStyle(ConsoleStyle.muted)
                    }.padding(24).background(ConsoleStyle.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack {
                    HStack {
                        Text(controller.selectedCameraName.uppercased())
                            .font(ConsoleStyle.mono(size: 9, weight: .medium)).tracking(1)
                            .lineLimit(1).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        if controller.running, let age = controller.telemetry.frameAgeSeconds {
                            Text(String(format: "FRAME AGE  %.2f s", age))
                                .font(ConsoleStyle.mono(size: 9)).foregroundStyle(live ? ConsoleStyle.cyan : ConsoleStyle.amber)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if let w = controller.telemetry.frameWidth, let h = controller.telemetry.frameHeight {
                            Text(String(format: "ANALYSIS  %d × %d", w, h)).font(ConsoleStyle.mono(size: 9))
                        } else { Text("CAMERA INPUT").font(ConsoleStyle.mono(size: 9)) }
                        Spacer()
                        Image(systemName: controller.showFineOutlines ? "viewfinder" : "square.dashed")
                        Text(contourMode)
                            .font(ConsoleStyle.mono(size: 9))
                    }.foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 4))
                }.padding(18).allowsHitTesting(false).accessibilityHidden(showingModel)
                if controller.running && !guidingOrbit { FocusOverlay(controller: controller) }
                if controller.running && guidingOrbit { orbitViewfinder }
                if page == .analysis && !showingModel && !controller.focusSelecting {
                    TargetScanOverlay(scan: controller.targetScan,
                        imageSize: CGSize(width: controller.telemetry.frameWidth ?? 0, height: controller.telemetry.frameHeight ?? 0),
                        mirrored: controller.mirror)
                }
                if showingModel, let url = reconstruction.outputURL {
                    ModelSceneView(outputURL: url, annotations: reconstruction.linkedAnalysis?.annotations ?? [],
                                   singleViewPrediction: reconstruction.singleViewPrediction)
                }
                ConsoleCorners().stroke(ConsoleStyle.text.opacity(0.35), lineWidth: 1)
                    .padding(10).allowsHitTesting(false).accessibilityHidden(true)
            }.clipped()
        }
        .background(ConsoleStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ConsoleStyle.line, lineWidth: 1))
    }

    private var orbitViewfinder: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: controller.telemetry.frameWidth ?? 0, height: controller.telemetry.frameHeight ?? 0)
            let image = FocusRegion.imageRect(view: geometry.size, image: imageSize)
            if !image.isEmpty {
                ZStack(alignment: .top) {
                    ConsoleCorners().stroke(ConsoleStyle.red.opacity(0.88), lineWidth: 2)
                    Text(orbitViewfinderTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ConsoleStyle.red)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(ConsoleStyle.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                        .offset(y: -30)
                }
                .frame(width: image.width * 0.59, height: image.height * 0.68)
                .position(x: image.midX, y: image.midY)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private var orbitViewfinderTitle: String {
        if autoOrbit.phase == .searching { return "将要建模的物体对准画面中央" }
        if autoOrbit.active { return "\(autoOrbit.step.title)  /  保持同一物体完整可见" }
        return "\(guidedOrbit.step.title)  /  保持物体完整可见"
    }

    private func beginAutomaticOrbit() {
        guard canStartAutomaticOrbit, !autoOrbit.active else { return }
        showingModel = false
        orbitEntryError = nil
        autoOrbit.start(controller: controller)
        page = .studio
    }

    private func beginGuidedOrbit() {
        let capture = controller.objectCapture
        guard live, reconstruction.isSupported, !reconstruction.isBusy, !capture.isCapturing, !capture.isFinishing,
              let width = controller.telemetry.frameWidth, let height = controller.telemetry.frameHeight,
              guidedOrbit.begin(scan: controller.targetScan) else { return }
        capture.start(region: nil, source: controller.telemetry.capturedSource ?? controller.selectedCameraName,
                      imageSize: CGSize(width: width, height: height), guided: true)
        guard capture.isCapturing else {
            orbitEntryError = capture.message
            guidedOrbit.reset()
            return
        }
        orbitEntryError = nil
        controller.focusSelecting = false
        showingModel = false
        page = .studio
    }

    private var standby: some View {
        ZStack {
            ConsoleStyle.background
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(ConsoleStyle.line, lineWidth: 1).frame(width: 88, height: 88)
                    Circle().stroke(ConsoleStyle.red.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [2, 7])).frame(width: 114, height: 114)
                    ConsoleGlyph(size: 40)
                }.accessibilityHidden(true)
                VStack(spacing: 9) {
                    Text(controller.loading ? "正在准备感知引擎" : "视觉系统待命").font(.system(size: 21, weight: .light)).tracking(2)
                    Text("让现实进入视野").font(.system(size: 12)).foregroundStyle(ConsoleStyle.muted)
                }
                if !controller.loading {
                    Button("启动摄像头", action: controller.start)
                        .buttonStyle(ConsoleButtonStyle(primary: true)).disabled(controller.renderer == nil)
                }
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(InspectorPage.allCases, id: \.self) { target in
                    Button { page = target } label: {
                        HStack(spacing: 7) {
                            Image(systemName: target.symbol)
                            Text(target.rawValue)
                            if target == .targets {
                                Text(String(format: "%02d", visibleCount)).font(ConsoleStyle.mono(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background((page == target ? ConsoleStyle.red : ConsoleStyle.muted).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }.font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 11)
                            .foregroundStyle(page == target ? ConsoleStyle.text : ConsoleStyle.muted)
                            .background(page == target ? ConsoleStyle.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(alignment: .bottom) {
                                if page == target { Capsule().fill(ConsoleStyle.red).frame(width: 24, height: 2) }
                            }
                    }.buttonStyle(.plain).accessibilityLabel(target.accessibilityLabel)
                        .accessibilityAddTraits(page == target ? [.isSelected] : [])
                        .disabled(autoOrbit.active && target != .studio)
                }
            }.padding(6)
            Rectangle().fill(ConsoleStyle.line).frame(height: 1)
            if page == .targets { targetsPanel }
            else if page == .analysis {
                VStack(spacing: 0) {
                    TargetScanPanel(scan: controller.targetScan, running: controller.running, onStart: {
                        showingModel = false
                        controller.startTargetScan()
                    }, onStop: controller.stopTargetScan, onShuffle: controller.shuffleTargetScan,
                        onOrbit: live && reconstruction.isSupported && !reconstruction.isBusy && guidedOrbit.target == nil
                            && !controller.objectCapture.isCapturing && !controller.objectCapture.isFinishing ? beginGuidedOrbit : nil)
                    .disabled(controller.loading || controller.reconstructionBusy || controller.renderer == nil)
                    if let orbitEntryError {
                        Text(orbitEntryError).font(.system(size: 10)).foregroundStyle(ConsoleStyle.amber).padding(8)
                    }
                }
            }
            else if page == .controls { controlsPanel }
            else { ObjectStudioPanel(controller: controller, capture: controller.objectCapture, reconstruction: reconstruction,
                                     guide: guidedOrbit, automatic: autoOrbit, showingModel: $showingModel) }
        }
        .frame(maxHeight: .infinity)
        .background(ConsoleStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ConsoleStyle.line, lineWidth: 1))
    }

    private var targetsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(controller.focusRegion == nil ? "目标情报" : "区域目标").font(.system(size: 17, weight: .medium))
                    Text("OBJECT INTELLIGENCE").font(ConsoleStyle.mono(size: 8)).tracking(1.6).foregroundStyle(ConsoleStyle.muted)
                }
                Spacer()
                Text(String(format: "%02d", visibleCount)).font(ConsoleStyle.mono(size: 30, weight: .light)).foregroundStyle(ConsoleStyle.cyan)
            }.padding(18)
            HStack(spacing: 7) {
                Circle().fill(ConsoleStyle.cyan).frame(width: 4, height: 4)
                Text("\(visibleCount) 个可见")
                Text("/").foregroundStyle(ConsoleStyle.line)
                Text("\(missingCount) 个暂失").foregroundStyle(missingCount > 0 ? ConsoleStyle.amber : ConsoleStyle.muted)
                Spacer()
                Text("TRACK ID").font(ConsoleStyle.mono(size: 8))
            }.font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted).padding(.horizontal, 18).padding(.bottom, 14)
            Rectangle().fill(ConsoleStyle.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if controller.focusedObjects.isEmpty {
                        VStack(spacing: 13) {
                            Image(systemName: "scope").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(ConsoleStyle.muted)
                            Text(controller.running ? "等待目标进入视野" : "目标将在这里出现").font(.system(size: 12))
                            Text("识别类别、置信度与短时轨迹\n选择 A / B 可比较相对深度")
                                .font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted).multilineTextAlignment(.center).lineSpacing(4)
                        }.frame(maxWidth: .infinity).padding(.vertical, 44)
                    }
                    ForEach(controller.focusedObjects) { item in objectRow(item) }
                }.padding(12)
            }
            Rectangle().fill(ConsoleStyle.line).frame(height: 1)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle").foregroundStyle(ConsoleStyle.red)
                Text("置信度是模型分数，并非正确率。\n轨迹编号仅用于短时跟踪。")
                    .font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted).lineSpacing(3)
            }.padding(14)
        }
    }

    private func objectRow(_ item: ObjectRow) -> some View {
        let color = item.color.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } ?? ConsoleStyle.muted
        let role = item.id == controller.pairChoice.a ? "A" : item.id == controller.pairChoice.b ? "B" : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 5, height: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(String(format: "TRACK / %03d", item.id)).font(ConsoleStyle.mono(size: 8)).tracking(0.8).foregroundStyle(ConsoleStyle.muted)
                }
                Spacer(minLength: 4)
                if let role { ConsoleTag(role, color: ConsoleStyle.red) }
                if !item.isObserved {
                    Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(ConsoleStyle.amber).accessibilityLabel("暂时丢失")
                }
            }
            HStack {
                Text(item.isObserved ? "置信度" : "上次置信度").font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted)
                Spacer()
                Text(String(format: "%.1f", Double(item.confidence) * 100)).font(ConsoleStyle.mono(size: 15, weight: .medium))
                Text("%").font(ConsoleStyle.mono(size: 9)).foregroundStyle(ConsoleStyle.muted)
            }
            GeometryReader { bounds in
                ZStack(alignment: .leading) {
                    Capsule().fill(ConsoleStyle.line)
                    Capsule().fill(item.isObserved ? color.opacity(0.8) : ConsoleStyle.amber.opacity(0.5))
                        .frame(width: bounds.size.width * CGFloat(min(1, max(0, item.confidence))))
                }
            }.frame(height: 2).accessibilityHidden(true)
            HStack(spacing: 6) {
                if !item.isObserved {
                    Text(String(format: "暂失 · %.1f 秒前出现", item.secondsSinceSeen))
                        .foregroundStyle(ConsoleStyle.amber)
                } else if controller.recognitionMode == .text {
                    Text("文字匹配 · 轮廓估计").foregroundStyle(ConsoleStyle.muted)
                } else if let depth = item.depth {
                    Text(String(format: "估计深度 %.2f m", depth))
                        .foregroundStyle(ConsoleStyle.muted)
                } else if controller.isDepthRequested {
                    Text("深度待更新")
                        .foregroundStyle(ConsoleStyle.muted)
                }
                Spacer(minLength: 0)
                if controller.recognitionMode == .fast {
                    pairShortcut(item, asA: true)
                    pairShortcut(item, asA: false)
                }
            }.font(.system(size: 9))
            if !item.otherClassScores.isEmpty {
                Text("其他类别：" + item.otherClassScores).font(.system(size: 9)).foregroundStyle(ConsoleStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).background(item.isObserved ? ConsoleStyle.raised : ConsoleStyle.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(role == nil ? ConsoleStyle.line.opacity(0.7) : ConsoleStyle.red.opacity(0.6), lineWidth: 1))
    }

    private func pairShortcut(_ item: ObjectRow, asA: Bool) -> some View {
        let selected = asA ? controller.pairChoice.a : controller.pairChoice.b
        let other = asA ? controller.pairChoice.b : controller.pairChoice.a
        return Button {
            var next = controller.pairChoice
            if asA { next.a = item.id } else { next.b = item.id }
            controller.setPairChoice(next)
        } label: {
            Text(asA ? "A" : "B").font(ConsoleStyle.mono(size: 9, weight: .semibold))
                .frame(width: 24, height: 22)
                .foregroundStyle(selected == item.id ? ConsoleStyle.red : ConsoleStyle.text)
                .background(selected == item.id ? ConsoleStyle.red.opacity(0.13) : ConsoleStyle.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ConsoleStyle.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!controller.running || other == item.id || selected == item.id)
            .accessibilityLabel("将 \(item.name) 轨迹 \(item.id) 设为\(asA ? " A" : " B")")
            .help("设为目标 \(asA ? "A" : "B")")
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                ConsolePanel(title: "采集源", kicker: "INPUT / 01") {
                    Picker("摄像头", selection: $controller.cameraChoice) {
                        Text("自动选择（优先内置）").tag("auto")
                        ForEach(controller.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        if controller.cameraChoice != "auto" && !controller.cameras.contains(where: { $0.uniqueID == controller.cameraChoice }) {
                            Text("已选摄像头不可用").tag(controller.cameraChoice)
                        }
                    }.labelsHidden().disabled(controller.running).accessibilityLabel("摄像头来源")
                    Toggle("镜像画面", isOn: $controller.mirror).toggleStyle(.switch).controlSize(.mini)
                    note("停止采集后可切换摄像头。手机画面请选择 Camo Camera。")
                }
                ConsolePanel(title: "识别引擎", kicker: "RECOGNITION / 02") {
                    Picker("识别方式", selection: Binding(get: { controller.recognitionMode }, set: controller.changeRecognitionMode)) {
                        Text("自动识别").tag(RecognitionMode.fast)
                        Text("文字找物").tag(RecognitionMode.text)
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("识别方式")
                    if controller.recognitionMode == .fast {
                        if controller.efficientModelAvailable {
                            Picker("性能配置", selection: Binding(get: { controller.performanceProfile }, set: controller.changePerformanceProfile)) {
                                Text("参考精度 / Reference").tag(RecognitionPerformance.reference)
                                Text("高效预览 / Efficient").tag(RecognitionPerformance.efficient)
                            }.disabled(controller.running || controller.loading)
                            note(controller.performanceProfile == .efficient ? "高效预览可能改变部分分数和细小掩膜。" : "参考配置保留原始精度。停止采集后可切换。")
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "cpu").foregroundStyle(ConsoleStyle.red)
                            Text(controller.loading ? "模型加载中" : controller.modelStatus).lineLimit(3)
                        }.font(ConsoleStyle.mono(size: 9)).foregroundStyle(ConsoleStyle.muted)
                        note("\(controller.classCount) 个词表名称，包含物体和场景概念；并非都能可靠识别。")
                    } else {
                        note("OWLv2 + SAM 2 · 按指定英文名称搜索，处理速度较慢。")
                    }
                    DisclosureGroup("自定义搜索词", isExpanded: $showPrompts) {
                        VStack(alignment: .leading, spacing: 9) {
                            TextField("英文名称，以逗号分隔", text: $controller.promptDraft, axis: .vertical)
                                .lineLimit(3...6).textFieldStyle(.roundedBorder).font(.system(size: 11))
                                .accessibilityLabel("自定义识别类别")
                            Button("应用并查找", action: controller.applyPrompts).buttonStyle(ConsoleButtonStyle())
                            note("支持 1–32 个不同英文名称，例如 headphones, keys, bottle。")
                            if controller.recognitionMode == .text {
                                note("当前搜索：" + controller.activePrompts.joined(separator: ", "))
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 11))
                    if !controller.promptError.isEmpty {
                        Text(controller.promptError).font(.system(size: 10)).foregroundStyle(ConsoleStyle.amber)
                    }
                }
                ConsolePanel(title: "轮廓渲染", kicker: "BOUNDARIES / 03") {
                    Toggle("显示精细描边", isOn: $controller.showFineOutlines).toggleStyle(.switch).controlSize(.mini)
                    if controller.recognitionMode == .fast {
                        Toggle("SAM 实时细化", isOn: $controller.refineBoundaries).toggleStyle(.switch).controlSize(.mini)
                            .accessibilityLabel("SAM 实时细化")
                        note("细节在后台更新；过期或失配时采用当前原生分割。")
                    }
                    HStack {
                        Text("描边宽度")
                        Spacer()
                        Text(String(format: "%.1f px", controller.outlineWidth)).font(ConsoleStyle.mono(size: 11))
                    }.font(.system(size: 11))
                    Slider(value: $controller.outlineWidth, in: 1...4, step: 0.5).disabled(!controller.showFineOutlines)
                        .accessibilityLabel("描边宽度").accessibilityValue(String(format: "%.1f 像素", controller.outlineWidth))
                    note("细线、透明部分和遮挡边界仍可能不准确。")
                }
                ConsolePanel(title: "接受阈值", kicker: "CONFIDENCE / 04") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(controller.recognitionMode == .fast ? "新目标置信度" : "搜索置信度").font(.system(size: 11))
                        Spacer()
                        Text(String(format: "%.0f", controller.minimumConfidence * 100)).font(ConsoleStyle.mono(size: 24, weight: .light))
                        Text("%").font(ConsoleStyle.mono(size: 11)).foregroundStyle(ConsoleStyle.muted)
                    }
                    Slider(value: $controller.minimumConfidence, in: 0.15...0.70, step: 0.05)
                        .accessibilityLabel("新目标置信度阈值").accessibilityValue(String(format: "%.0f 百分比", controller.minimumConfidence * 100))
                    note("调低可发现更多候选，调高可减少误报。已建立轨迹可由较弱观测延续。")
                }
                DisclosureGroup("运行细节", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(controller.recognitionStatus)
                        Text(controller.distanceStatus)
                        Text(controller.metrics)
                    }.font(ConsoleStyle.mono(size: 9)).foregroundStyle(ConsoleStyle.muted)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.system(size: 11)).padding(12)
            }.padding(12)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pairBinding<Value>(_ keyPath: WritableKeyPath<ObjectPairChoice, Value>) -> Binding<Value> {
        Binding { controller.pairChoice[keyPath: keyPath] } set: { value in
            var next = controller.pairChoice
            next[keyPath: keyPath] = value
            controller.setPairChoice(next)
        }
    }

    private func objectPicker(_ letter: String, selection: Binding<Int?>, otherID: Int?) -> some View {
        let candidates = controller.focusedObjects.filter { $0.id != otherID }
        let selected = selection.wrappedValue
        return HStack(spacing: 8) {
            Text(letter).font(ConsoleStyle.mono(size: 12, weight: .semibold)).foregroundStyle(ConsoleStyle.red)
                .frame(width: 26, height: 28).background(ConsoleStyle.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
            Picker("目标 \(letter)", selection: selection) {
                Text("选择目标 \(letter)").tag(nil as Int?)
                ForEach(candidates) { item in
                    Text("\(item.name) #\(item.id)\(item.isObserved ? "" : " · 暂失")").tag(Optional(item.id))
                }
                if let selected, !candidates.contains(where: { $0.id == selected }) {
                    Text("轨迹 #\(selected) · 已丢失").tag(Optional(selected))
                }
            }.labelsHidden().accessibilityLabel("目标 \(letter)")
                .disabled(!controller.running || (selected == nil && candidates.isEmpty))
        }.frame(maxWidth: .infinity)
    }

    private var pairDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text("02").font(ConsoleStyle.mono(size: 10)).foregroundStyle(ConsoleStyle.red)
                Text("相对深度").font(.system(size: 12, weight: .semibold))
                Text("DEPTH RELATION").font(ConsoleStyle.mono(size: 8)).tracking(1.3).foregroundStyle(ConsoleStyle.muted)
                Spacer()
                Picker("复测策略", selection: pairBinding(\.adaptive)) {
                    Text("自适应").tag(true)
                    Text("五秒基线").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 174)
                    .disabled(controller.recognitionMode == .text).accessibilityLabel("复测策略")
                Button(action: controller.clearPair) { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(ConsoleButtonStyle()).help("清除 A / B 选择").accessibilityLabel("清除目标比较")
                    .disabled(controller.pairChoice.a == nil && controller.pairChoice.b == nil)
            }
            if controller.recognitionMode == .text {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent").foregroundStyle(ConsoleStyle.muted)
                    Text("切回自动识别，即可选择两个目标比较相对深度。")
                        .font(.system(size: 11)).foregroundStyle(ConsoleStyle.muted)
                }.frame(height: 68)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    VStack(spacing: 8) {
                        objectPicker("A", selection: pairBinding(\.a), otherID: controller.pairChoice.b)
                        objectPicker("B", selection: pairBinding(\.b), otherID: controller.pairChoice.a)
                    }.frame(maxWidth: .infinity)
                    Rectangle().fill(ConsoleStyle.line).frame(width: 1, height: 62)
                    pairResult.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(15).background(ConsoleStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ConsoleStyle.line, lineWidth: 1))
    }

    private var pairResult: some View {
        let presentation = controller.pairPresentation
        let certain = presentation?.state == .aCloser || presentation?.state == .bCloser
        let neutral = presentation == nil || presentation?.state == .choose
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: certain ? "checkmark.circle" : neutral ? "circle.dashed" : "clock")
                    .foregroundStyle(certain ? ConsoleStyle.cyan : neutral ? ConsoleStyle.muted : ConsoleStyle.amber)
                Text(presentation?.localizedTitle ?? "选择 A 和 B")
                    .font(.system(size: 15, weight: .medium)).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(presentation?.localizedDetail ?? "从目标列表或左侧菜单中选择。")
                .font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted).lineLimit(3)
            Text("单目深度估计 · 未经距离标定").font(.system(size: 9)).foregroundStyle(ConsoleStyle.muted)
        }.frame(minHeight: 66)
    }

    private var telemetryStrip: some View {
        let t = controller.telemetry
        return HStack(spacing: 0) {
            metric("识别", code: "DETECTION", value: number(t.detectionFPS), unit: "FPS", color: ConsoleStyle.text)
            metricSeparator
            metric("分析画面显示", code: "DISPLAY", value: number(t.displayFPS), unit: "FPS", color: ConsoleStyle.cyan)
            metricSeparator
            metric("细描边更新", code: "REFINEMENT", value: number(t.samFPS), unit: "Hz", color: ConsoleStyle.text)
            metricSeparator
            metric("处理延迟 P95", code: "CALLBACK → GPU", value: number(t.latencyP95MS, decimals: 0), unit: "ms", color: ConsoleStyle.text)
            metricSeparator
            metric("细轮廓覆盖", code: "ELIGIBLE TARGETS", value: t.fineCount.flatMap { fine in t.totalContourCount.map { "\(fine)/\($0)" } } ?? "—", unit: "", color: ConsoleStyle.cyan)
        }.padding(.vertical, 13).background(ConsoleStyle.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ConsoleStyle.line, lineWidth: 1))
            .help("识别、显示和细化分别计时。覆盖数量代表通过复用检查，不代表轮廓准确率；延迟不包含物理屏幕响应。")
    }

    private var metricSeparator: some View { Rectangle().fill(ConsoleStyle.line).frame(width: 1, height: 35) }

    private func metric(_ title: String, code: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9)).foregroundStyle(ConsoleStyle.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(ConsoleStyle.mono(size: 23, weight: .light)).foregroundStyle(color).contentTransition(.identity)
                Text(unit).font(ConsoleStyle.mono(size: 8)).foregroundStyle(ConsoleStyle.muted)
            }.lineLimit(1).minimumScaleFactor(0.75)
            Text(code).font(ConsoleStyle.mono(size: 7)).tracking(0.5).foregroundStyle(ConsoleStyle.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title) \(value) \(unit)")
    }

    private func number(_ value: Double?, decimals: Int = 1) -> String {
        value.map { String(format: "%.*f", decimals, $0) } ?? "—"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !controller.error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(controller.error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundStyle(ConsoleStyle.red)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConsoleStyle.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else if let notice = serviceNotice {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(notice).lineLimit(2).help(notice).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("查看控制") { page = .controls; showDiagnostics = true }
                        .buttonStyle(ConsoleButtonStyle())
                }.font(.system(size: 10)).foregroundStyle(ConsoleStyle.amber)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConsoleStyle.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 7) {
                Circle().fill(signalColor).frame(width: 4, height: 4)
                Text(showingModel ? "三维查看 · 拖动旋转，滚动缩放" : controller.running ? controller.status : controller.loading ? "正在加载本机模型" : "系统待命 · 启动摄像头开始识别")
                    .font(.system(size: 9)).foregroundStyle(ConsoleStyle.muted).lineLimit(1)
                Spacer(minLength: 10)
                if let capture = controller.telemetry.captureFPS {
                    Text(String(format: "CAPTURE %.1f FPS", capture)).font(ConsoleStyle.mono(size: 8)).foregroundStyle(ConsoleStyle.muted)
                }
                Text("/  最新版").font(ConsoleStyle.mono(size: 8)).tracking(1.3).foregroundStyle(ConsoleStyle.muted)
            }
        }
    }
}
#endif
