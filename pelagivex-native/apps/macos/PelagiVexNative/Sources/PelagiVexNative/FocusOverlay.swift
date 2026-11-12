#if os(macOS)
import SwiftUI
import VisionCore

struct FocusOverlay: View {
    @ObservedObject var controller: AppController
    @State private var drag: FocusRegion?
    var body: some View {
        GeometryReader { proxy in
            let image = CGSize(width: controller.telemetry.frameWidth ?? 0, height: controller.telemetry.frameHeight ?? 0)
            let rect = (controller.focusSelecting ? (drag ?? controller.focusRegion) : controller.focusRegion)?.displayRect(view: proxy.size, image: image, mirrored: controller.mirror)
            ZStack(alignment: .topLeading) {
                if let rect, !rect.isEmpty {
                    Path { p in p.addRect(CGRect(origin: .zero, size: proxy.size)); p.addRect(rect) }
                        .fill(.black.opacity(0.53), style: FillStyle(eoFill: true))
                    Rectangle().stroke(ConsoleStyle.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [7, 3]))
                        .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    Text("FOCUS / 聚焦区域").font(ConsoleStyle.mono(size: 10, weight: .semibold))
                        .padding(6).background(ConsoleStyle.cyan).foregroundStyle(.black)
                        .offset(x: rect.minX, y: max(0, rect.minY - 25))
                }
                if controller.focusSelecting {
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            drag = FocusRegion.selection(start: value.startLocation, end: value.location,
                                view: proxy.size, image: image, mirrored: controller.mirror)
                        }
                        .onEnded { value in
                            if let region = FocusRegion.selection(start: value.startLocation, end: value.location,
                                view: proxy.size, image: image, mirrored: controller.mirror) { controller.setFocus(region) }
                            drag = nil
                        })
                    Text("在画面内拖动，框住整个物体并留出绕拍余量")
                        .font(.system(size: 12)).padding(12).background(ConsoleStyle.panel, in: Capsule())
                        .position(x: proxy.size.width / 2, y: proxy.size.height - 60).allowsHitTesting(false)
                }
            }.allowsHitTesting(controller.focusSelecting)
                .onChange(of: controller.focusSelecting) { _, selecting in if !selecting { drag = nil } }
        }
    }
}
#endif
