#if os(macOS)
import AppKit
import SceneKit
import SwiftUI

struct ModelFeatureAnnotation: Codable, Equatable {
    let label: String
    let value: String
}

private let predictionBlue = NSColor(srgbRed: 0.24, green: 0.69, blue: 1, alpha: 1)

struct ModelSceneView: View {
    let outputURL: URL
    let annotations: [ModelFeatureAnnotation]
    let singleViewPrediction: Bool
    @State private var mesh: ScanMesh?
    @State private var loadError: String?
    @State private var wireframe = false
    @State private var showAnnotations = true
    @State private var reset = 0
    @State private var zoom = 0

    init(outputURL: URL, annotations: [ModelFeatureAnnotation] = [], singleViewPrediction: Bool = false) {
        self.outputURL = outputURL
        self.annotations = annotations
        self.singleViewPrediction = singleViewPrediction
    }

    var body: some View {
        VStack(spacing: 0) {
            if singleViewPrediction {
                HStack(spacing: 8) {
                    ConsoleTag("单视角预测", color: Color(nsColor: predictionBlue))
                    Text("蓝色体积线框 · 背面和厚度根据单张照片推测")
                        .font(.system(size: 11)).foregroundStyle(ConsoleStyle.muted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(ConsoleStyle.panel)
            }
            if let mesh, mesh.url == outputURL {
                ScanSceneSurface(mesh: mesh, wireframe: wireframe, reset: reset, zoom: zoom,
                                 annotations: showAnnotations ? annotations : [], singleViewPrediction: singleViewPrediction)
                    .id(outputURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    if let loadError {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(ConsoleStyle.amber)
                        Text("模型无法在工作台打开").font(.system(size: 14, weight: .semibold))
                        Text(loadError).font(.system(size: 11)).foregroundStyle(ConsoleStyle.muted)
                            .multilineTextAlignment(.center).lineLimit(4).textSelection(.enabled)
                        Button("用系统打开") { NSWorkspace.shared.open(outputURL) }
                            .buttonStyle(ConsoleButtonStyle())
                    } else {
                        ProgressView().controlSize(.small)
                        Text("正在读取 USDZ 网格").font(.system(size: 12)).foregroundStyle(ConsoleStyle.muted)
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(outputURL.lastPathComponent).font(ConsoleStyle.mono(size: 10, weight: .semibold))
                        .lineLimit(1).help(outputURL.path)
                    Text("拖动旋转 · 滚动缩放").font(.system(size: 10)).foregroundStyle(ConsoleStyle.muted)
                }
                Spacer(minLength: 8)
                if !annotations.isEmpty {
                    Toggle("特征标注", isOn: $showAnnotations).toggleStyle(.switch).controlSize(.mini)
                }
                if !singleViewPrediction {
                    Toggle("线框", isOn: $wireframe).toggleStyle(.switch).controlSize(.mini)
                }
                Button { zoom -= 1 } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("缩小模型").help("缩小模型")
                Button { zoom += 1 } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(ConsoleButtonStyle()).accessibilityLabel("放大模型").help("放大模型")
                Button("重置相机") { reset += 1 }
                    .buttonStyle(ConsoleButtonStyle())
            }
            .disabled(mesh?.url != outputURL)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(ConsoleStyle.panel)
        }
        .background(ConsoleStyle.background)
        .task(id: outputURL) { await load() }
    }

    private func load() async {
        mesh = nil
        loadError = nil
        let url = outputURL
        do {
            let result = try await Task.detached(priority: .userInitiated) { try ScanMesh.load(url) }.value
            try Task.checkCancellation()
            zoom = 0
            reset = 0
            mesh = result
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }
}

/// The loader owns the scene until it transfers it to the main-thread viewer.
private struct ScanMesh: @unchecked Sendable {
    let url: URL
    let scene: SCNScene
    let center: SCNVector3
    let radius: CGFloat
    let corners: [SCNVector3]
    let featureAnchor: SCNVector3

    static func load(_ url: URL) throws -> ScanMesh {
        let scene = try SCNScene(url: url, options: [.checkConsistency: true, .convertToYUp: true])
        let root = scene.rootNode
        let hasGeometry = root.geometry != nil || !root.childNodes(passingTest: { node, _ in node.geometry != nil }).isEmpty
        let (minimum, maximum) = root.boundingBox
        let width = maximum.x - minimum.x, height = maximum.y - minimum.y, depth = maximum.z - minimum.z
        let radius = sqrt(width * width + height * height + depth * depth) / 2
        let center = SCNVector3(minimum.x + width / 2, minimum.y + height / 2, minimum.z + depth / 2)
        guard hasGeometry, [center.x, center.y, center.z, radius].allSatisfy(\.isFinite), radius > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "USDZ 中没有可查看的有效三维几何。"])
        }
        var corners: [SCNVector3] = []
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] { corners.append(SCNVector3(x, y, z)) }
            }
        }
        // An interior offset from the pivot keeps the marker visibly tied to the mesh as it orbits.
        let featureAnchor = SCNVector3(center.x + width * 0.16, center.y + height * 0.14, center.z + depth * 0.18)
        return ScanMesh(url: url, scene: scene, center: center, radius: radius, corners: corners, featureAnchor: featureAnchor)
    }
}

private struct ScanSceneSurface: NSViewRepresentable {
    let mesh: ScanMesh
    let wireframe: Bool
    let reset: Int
    let zoom: Int
    let annotations: [ModelFeatureAnnotation]
    let singleViewPrediction: Bool

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let camera = SCNNode()
        var lastReset = 0
        var lastZoom = 0
        weak var overlay: ModelFeatureOverlay?
        private var predictionGeometries: [(node: SCNNode, original: SCNGeometry)] = []

        func setPredictionStyle(_ enabled: Bool, root: SCNNode) {
            if !enabled {
                for (node, original) in predictionGeometries { node.geometry = original }
                predictionGeometries.removeAll()
                return
            }
            guard predictionGeometries.isEmpty else { return }
            let material = SCNMaterial()
            material.lightingModel = .lambert
            material.diffuse.contents = predictionBlue
            material.emission.contents = NSColor(srgbRed: 0.065, green: 0.36, blue: 0.69, alpha: 1)
            material.fillMode = .lines
            let nodes = [root] + root.childNodes(passingTest: { node, _ in node.geometry != nil })
            for node in nodes {
                guard let original = node.geometry, let lines = original.copy() as? SCNGeometry else { continue }
                lines.materials = [material]
                node.geometry = lines
                predictionGeometries.append((node, original))
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            // The scene renders on a separate thread. AppKit redraws just the overlay on the main thread.
            DispatchQueue.main.async { [weak self] in self?.overlay?.needsDisplay = true }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScanSceneHost {
        let host = ScanSceneHost(mesh: mesh)
        let view = host.sceneView
        let background = NSColor(srgbRed: 9 / 255, green: 12 / 255, blue: 18 / 255, alpha: 1)
        view.backgroundColor = background
        view.autoenablesDefaultLighting = true
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.antialiasingMode = .multisampling2X
        mesh.scene.background.contents = background
        let node = context.coordinator.camera
        let lens = SCNCamera()
        lens.fieldOfView = 38
        lens.zNear = Double(mesh.radius) * 0.005
        lens.zFar = Double(mesh.radius) * 80
        node.camera = lens
        mesh.scene.rootNode.addChildNode(node)
        view.scene = mesh.scene
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.inertiaEnabled = false
        resetCamera(view, node: node)
        context.coordinator.lastReset = reset
        context.coordinator.lastZoom = zoom
        context.coordinator.overlay = host.overlay
        return host
    }

    func updateNSView(_ host: ScanSceneHost, context: Context) {
        let view = host.sceneView
        view.debugOptions = !singleViewPrediction && wireframe ? [.showWireframe] : []
        let coordinator = context.coordinator
        coordinator.setPredictionStyle(singleViewPrediction, root: mesh.scene.rootNode)
        host.overlay.annotations = annotations
        host.overlay.isPrediction = singleViewPrediction
        host.overlay.isHidden = annotations.isEmpty
        view.delegate = annotations.isEmpty ? nil : coordinator
        let summary = annotations.map { "\($0.label) \($0.value)" }.joined(separator: "。")
        let accessibilityTitle = singleViewPrediction ? "单视角预测三维线框。背面和厚度为推测。" : "三维模型。"
        view.setAccessibilityLabel(accessibilityTitle + "拖动旋转，滚动缩放。" + summary)
        if coordinator.lastReset != reset {
            resetCamera(view, node: coordinator.camera)
            coordinator.lastReset = reset
        } else if coordinator.lastZoom != zoom, let camera = view.pointOfView {
            let target = view.defaultCameraController.target
            let position = camera.worldPosition
            let x = position.x - target.x, y = position.y - target.y, z = position.z - target.z
            let distance = sqrt(x * x + y * y + z * z)
            if distance.isFinite, distance > 0 {
                let factor = pow(0.82, CGFloat(zoom - coordinator.lastZoom))
                let next = min(mesh.radius * 30, max(mesh.radius * 0.55, distance * factor)) / distance
                camera.worldPosition = SCNVector3(target.x + x * next, target.y + y * next, target.z + z * next)
            }
        }
        coordinator.lastZoom = zoom
        host.overlay.needsDisplay = !annotations.isEmpty
    }

    static func dismantleNSView(_ host: ScanSceneHost, coordinator: Coordinator) {
        host.sceneView.delegate = nil
        if let root = host.sceneView.scene?.rootNode { coordinator.setPredictionStyle(false, root: root) }
        coordinator.camera.removeFromParentNode()
    }

    private func resetCamera(_ view: SCNView, node: SCNNode) {
        view.defaultCameraController.stopInertia()
        let center = mesh.center, radius = mesh.radius
        node.position = SCNVector3(center.x + 0.65 * radius, center.y + 0.45 * radius, center.z + 3.5 * radius)
        node.look(at: center)
        view.pointOfView = node
        view.defaultCameraController.pointOfView = node
        view.defaultCameraController.target = center
    }
}

private final class ScanSceneHost: NSView {
    let sceneView = SCNView(frame: .zero)
    let overlay: ModelFeatureOverlay

    init(mesh: ScanMesh) {
        overlay = ModelFeatureOverlay(anchor: mesh.featureAnchor, corners: mesh.corners)
        super.init(frame: .zero)
        overlay.sceneView = sceneView
        overlay.isHidden = true
        overlay.wantsLayer = true
        overlay.setAccessibilityElement(false)
        for view in [sceneView, overlay] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }
}

private final class ModelFeatureOverlay: NSView {
    weak var sceneView: SCNView?
    var annotations: [ModelFeatureAnnotation] = []
    var isPrediction = false
    private let anchor: SCNVector3
    private let corners: [SCNVector3]
    private var accent: NSColor {
        isPrediction ? predictionBlue : NSColor(srgbRed: 255 / 255, green: 78 / 255, blue: 102 / 255, alpha: 1)
    }
    private let panel = NSColor(srgbRed: 12 / 255, green: 16 / 255, blue: 24 / 255, alpha: 0.96)

    init(anchor: SCNVector3, corners: [SCNVector3]) {
        self.anchor = anchor
        self.corners = corners
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    // A label can overlap the mesh at tight zoom levels, so all input goes to the orbit camera.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset: CGFloat = 14
        let rowHeight: CGFloat = 18
        let headerHeight: CGFloat = 42
        guard let view = sceneView, let root = view.scene?.rootNode, !annotations.isEmpty,
              bounds.width > 190, bounds.height >= inset * 2 + headerHeight + rowHeight,
              let pin = project(anchor, root: root, view: view), bounds.contains(pin) else { return }

        let screenCorners = corners.compactMap { project($0, root: root, view: view) }
        let left = screenCorners.map(\.x).min() ?? pin.x
        let right = screenCorners.map(\.x).max() ?? pin.x
        let leftSpace = left - bounds.minX
        let rightSpace = bounds.maxX - right
        let width = min(218, bounds.width - 2 * inset)
        let gap: CGFloat = 16
        let placeRight = rightSpace >= width + gap + inset || rightSpace >= leftSpace
        let edgeX = placeRight ? right + gap : left - gap - width
        let x = min(bounds.maxX - width - inset, max(bounds.minX + inset, edgeX))
        let maxRows = Int((bounds.height - 2 * inset - headerHeight) / rowHeight)
        let rows = Array(annotations.prefix(maxRows))
        let height = headerHeight + rowHeight * CGFloat(rows.count)
        let y = min(bounds.maxY - height - inset, max(bounds.minY + inset, pin.y + 36 - height / 2))
        let deck = CGRect(x: x, y: y, width: width, height: height)
        drawLeader(pin: pin, deck: deck)
        drawDeck(deck, rows: rows, hiddenRows: annotations.count - rows.count)
    }

    private func project(_ point: SCNVector3, root: SCNNode, view: SCNView) -> CGPoint? {
        let p = view.projectPoint(root.convertPosition(point, to: nil))
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, (0...1).contains(p.z) else { return nil }
        return convert(CGPoint(x: p.x, y: p.y), from: view)
    }

    private func drawLeader(pin: CGPoint, deck: CGRect) {
        let connectLeft = pin.x <= deck.midX
        let dock = CGPoint(x: connectLeft ? deck.minX : deck.maxX, y: deck.midY)
        let elbow = CGPoint(x: dock.x + (connectLeft ? -12 : 12), y: dock.y)
        let line = NSBezierPath()
        line.move(to: pin)
        line.line(to: elbow)
        line.line(to: dock)
        line.lineWidth = 1.5
        accent.withAlphaComponent(0.9).setStroke()
        line.stroke()
        let outer = NSBezierPath(ovalIn: CGRect(x: pin.x - 7, y: pin.y - 7, width: 14, height: 14))
        panel.setFill()
        outer.fill()
        accent.setStroke()
        outer.lineWidth = 1.5
        outer.stroke()
        accent.setFill()
        NSBezierPath(ovalIn: CGRect(x: pin.x - 2, y: pin.y - 2, width: 4, height: 4)).fill()
    }

    private func drawDeck(_ deck: CGRect, rows: [ModelFeatureAnnotation], hiddenRows: Int) {
        let shape = NSBezierPath(roundedRect: deck, xRadius: 6, yRadius: 6)
        panel.setFill()
        shape.fill()
        accent.withAlphaComponent(0.67).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        accent.setFill()
        NSBezierPath(rect: CGRect(x: deck.minX, y: deck.maxY - 19, width: 3, height: 11)).fill()

        let content = deck.insetBy(dx: 11, dy: 0)
        let caption = hiddenRows > 0 ? "扫描快照 · 整体属性 · +\(hiddenRows)" : "扫描快照 · 整体属性"
        drawText("特征标注", in: CGRect(x: content.minX, y: deck.maxY - 23, width: content.width, height: 16),
                 font: .systemFont(ofSize: 12, weight: .semibold), color: accent)
        drawText(caption, in: CGRect(x: content.minX, y: deck.maxY - 36, width: content.width, height: 14),
                 font: .systemFont(ofSize: 9), color: NSColor.white.withAlphaComponent(0.55))

        for (index, annotation) in rows.enumerated() {
            let y = deck.maxY - 54 - 18 * CGFloat(index)
            let labelWidth = content.width * 0.45
            let labelRect = CGRect(x: content.minX, y: y, width: labelWidth, height: 14)
            let valueRect = CGRect(x: labelRect.maxX + 4, y: y, width: content.width - labelWidth - 4, height: 14)
            drawText(annotation.label, in: labelRect, font: .systemFont(ofSize: 10), color: NSColor.white.withAlphaComponent(0.64))
            drawText(annotation.value, in: valueRect, font: .monospacedSystemFont(ofSize: 10, weight: .medium),
                     color: .white, alignment: .right)
        }
    }

    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}
#endif
