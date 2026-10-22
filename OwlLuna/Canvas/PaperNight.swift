import SwiftUI

extension PaperColor {
    /// How PencilKit shows ink on this paper. Only Chalkboard writes light; Charcoal keeps the ink its pages already have.
    var inkAppearance: UIUserInterfaceStyle { self == .chalkboard ? .dark : .light }

    /// Light paper as it is shown in Dark Mode: a dark sheet with a little of its own colour left in it.
    var nightRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .white: (0.133, 0.129, 0.125)
        case .ivory: (0.141, 0.129, 0.106)
        case .yellow: (0.145, 0.133, 0.086)
        case .gray: (0.137, 0.145, 0.157)
        case .kraft: (0.165, 0.129, 0.094)
        case .sage: (0.11, 0.141, 0.118)
        case .blush: (0.161, 0.118, 0.114)
        case .charcoal, .chalkboard: rgb
        }
    }
}

extension NotebookPage {
    /// Whether the page is shown dark at `night`: light paper is. A PDF or a photo keeps its own colours.
    func turnsDark(_ night: Bool) -> Bool { night && template != nil && !paperColor.isDark }

    /// Whether what lies on the page is drawn for dark paper.
    func isDark(night: Bool) -> Bool { effectivePaperColor.isDark || turnsDark(night) }

    func inkAppearance(night: Bool) -> UIUserInterfaceStyle { turnsDark(night) ? .dark : effectivePaperColor.inkAppearance }

    /// The colour of the page's paper as it is shown.
    func paperShown(night: Bool) -> UIColor { PageRenderer.paperColor(effectivePaperColor, night: turnsDark(night)) }
}

/// Whether light paper is shown dark: in Dark Mode, unless that is turned off in Settings. What is exported never is.
@propertyWrapper
struct PaperNight: DynamicProperty {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.darkPaper) private var isAllowed = true

    var wrappedValue: Bool { isAllowed && scheme == .dark }

    static func isOn(_ traits: UITraitCollection, defaults: UserDefaults = .standard) -> Bool {
        traits.userInterfaceStyle == .dark && defaults.bool(forKey: SettingsKey.darkPaper, default: true)
    }
}
