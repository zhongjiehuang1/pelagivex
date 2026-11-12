#if os(macOS)
import SwiftUI

enum ConsoleStyle {
    static let background = Color(red: 9 / 255, green: 12 / 255, blue: 18 / 255)
    static let panel = Color(red: 16 / 255, green: 22 / 255, blue: 32 / 255)
    static let raised = Color(red: 24 / 255, green: 33 / 255, blue: 46 / 255)
    static let line = Color(red: 43 / 255, green: 56 / 255, blue: 74 / 255)
    static let text = Color(red: 237 / 255, green: 243 / 255, blue: 250 / 255)
    static let muted = Color(red: 159 / 255, green: 175 / 255, blue: 194 / 255)
    static let red = Color(red: 255 / 255, green: 79 / 255, blue: 95 / 255)
    static let cyan = Color(red: 128 / 255, green: 216 / 255, blue: 208 / 255)
    static let amber = Color(red: 244 / 255, green: 189 / 255, blue: 115 / 255)

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct ConsolePanel<Content: View>: View {
    let title: String
    let kicker: String
    let content: Content

    init(title: String, kicker: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.kicker = kicker
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty || !kicker.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !kicker.isEmpty {
                        Text(kicker.uppercased())
                            .font(ConsoleStyle.mono(size: 10, weight: .semibold))
                            .tracking(1.25)
                            .foregroundStyle(ConsoleStyle.cyan)
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ConsoleStyle.text)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsoleStyle.panel, in: shape)
        .overlay { shape.strokeBorder(ConsoleStyle.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct ConsoleTag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = ConsoleStyle.cyan) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(ConsoleStyle.mono(size: 10, weight: .semibold))
            .tracking(0.45)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.32), lineWidth: 1).allowsHitTesting(false) }
    }
}

struct ConsoleButtonStyle: ButtonStyle {
    let primary: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(primary: Bool = false, destructive: Bool = false) {
        self.primary = primary
        self.destructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        let foreground: Color = primary ? ConsoleStyle.background : destructive ? ConsoleStyle.red : ConsoleStyle.text
        let fill: Color = primary ? ConsoleStyle.red : destructive ? ConsoleStyle.red.opacity(0.10) : ConsoleStyle.raised
        let border = primary || destructive ? ConsoleStyle.red.opacity(0.45) : ConsoleStyle.line
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? foreground : ConsoleStyle.muted.opacity(0.58))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(isEnabled ? fill.opacity(configuration.isPressed ? 0.75 : 1) : ConsoleStyle.raised.opacity(0.55), in: shape)
            .overlay { shape.strokeBorder(isEnabled ? border : ConsoleStyle.line.opacity(0.6), lineWidth: 1).allowsHitTesting(false) }
            .contentShape(shape)
    }
}

/// Two offset signal paths frame a central sample point.
struct ConsoleGlyph: View {
    var size: CGFloat = 32

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24)
        Canvas { context, bounds in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * bounds.width, y: y * bounds.height)
            }
            let upper = Path { path in
                path.addLines([point(0.19, 0.47), point(0.40, 0.26), point(0.68, 0.26), point(0.81, 0.39)])
            }
            let lower = Path { path in
                path.addLines([point(0.81, 0.53), point(0.60, 0.74), point(0.32, 0.74), point(0.19, 0.61)])
            }
            let sample = Path { path in
                path.addLines([point(0.50, 0.40), point(0.60, 0.50), point(0.50, 0.60), point(0.40, 0.50)])
                path.closeSubpath()
            }
            let stroke = StrokeStyle(lineWidth: max(1, size * 0.047), lineCap: .round, lineJoin: .round)
            context.stroke(upper, with: .color(ConsoleStyle.red), style: stroke)
            context.stroke(lower, with: .color(ConsoleStyle.red.opacity(0.64)), style: stroke)
            context.fill(sample, with: .color(ConsoleStyle.red))
        }
        .frame(width: size, height: size)
        .background(ConsoleStyle.raised, in: shape)
        .overlay { shape.strokeBorder(ConsoleStyle.line, lineWidth: 1) }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ConsoleCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let edge = min(rect.width, rect.height)
        guard edge > 0 else { return Path() }
        let inset = min(13, edge * 0.055)
        let frame = rect.insetBy(dx: inset, dy: inset)
        let arm = min(24, min(frame.width, frame.height) * 0.16)
        return Path { path in
            path.addLines([CGPoint(x: frame.minX, y: frame.minY + arm), CGPoint(x: frame.minX, y: frame.minY),
                           CGPoint(x: frame.minX + arm, y: frame.minY)])
            path.move(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
            path.move(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
            path.move(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))
        }
    }
}

struct ConsoleBackground: View {
    var body: some View {
        ZStack {
            ConsoleStyle.background
            RadialGradient(colors: [ConsoleStyle.red.opacity(0.09), .clear],
                           center: UnitPoint(x: 0.17, y: 0), startRadius: 10, endRadius: 510)
            Canvas { context, size in
                let spacing: CGFloat = 36
                var grid = Path()
                for x in stride(from: spacing, to: size.width, by: spacing) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: spacing, to: size.height, by: spacing) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(ConsoleStyle.line.opacity(0.34)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
#endif
