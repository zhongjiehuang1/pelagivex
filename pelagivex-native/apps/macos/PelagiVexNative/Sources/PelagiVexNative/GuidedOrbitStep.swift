#if os(macOS)
enum GuidedOrbitStep: Int, CaseIterable, Identifiable, Sendable {
    case front, firstSide, back, secondSide, upper

    static let recommendedPhotos = 4

    var id: Int { rawValue }
    var next: Self? { Self(rawValue: rawValue + 1) }

    var key: String {
        switch self {
        case .front: "front"
        case .firstSide: "firstSide"
        case .back: "back"
        case .secondSide: "secondSide"
        case .upper: "upper"
        }
    }

    var title: String {
        switch self {
        case .front: "正面起拍"
        case .firstSide: "第一侧面"
        case .back: "背面绕拍"
        case .secondSide: "另一侧面"
        case .upper: "高角度补拍"
        }
    }
}
#endif
