import UIKit
import PencilKit

/// The colours text is highlighted in from the selection bar.
enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, pink, blue
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .pink: String(localized: "Pink")
        case .blue: String(localized: "Blue")
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yellow: UIColor(hex: 0xFFD426)
        case .green: UIColor(hex: 0x7ED98B)
        case .pink: UIColor(hex: 0xFF8FB8)
        case .blue: UIColor(hex: 0x7CC4FF)
        }
    }

    static var last: HighlightColor {
        get { UserDefaults.standard.string(forKey: SettingsKey.highlightColor).flatMap(HighlightColor.init(rawValue:)) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.highlightColor) }
    }
}

/// A highlighter stroke laid over a line of text: straight, and as tall as the line.
enum TextHighlight {
    /// How much taller than its points' size a marker stroke is drawn, with the chisel held across the stroke.
    static let spread: CGFloat = 1.43

    /// The stroke that covers `rect`. It takes the pressure and opacity of the stroke it stands in for, if there is one.
    static func stroke(over rect: CGRect, ink: PKInk, replacing drawn: PKStroke? = nil, date: Date = .now) -> PKStroke {
        let upright = rect.height > rect.width
        let length = upright ? rect.height : rect.width, thickness = upright ? rect.width : rect.height
        let unit = min(max(thickness / spread, 3), 60)
        // The chisel's ends reach a little past the path's.
        let lead = min(unit * 0.25, length / 2 - 0.5), trail = min(unit * 0.18, length / 2 - 0.5)
        let run = max(length - lead - trail, 1), steps = max(Int(run / 16), 3)
        let sample = drawn.flatMap { stroke in stroke.path.isEmpty ? nil : stroke.path[stroke.path.count / 2] }
        let points = (0...steps).map { step -> PKStrokePoint in
            let along = lead + run * CGFloat(step) / CGFloat(steps)
            let location = upright ? CGPoint(x: rect.midX, y: rect.minY + along) : CGPoint(x: rect.minX + along, y: rect.midY)
            return PKStrokePoint(location: location, timeOffset: 0.2 * Double(step) / Double(steps), size: CGSize(width: unit, height: unit),
                                 opacity: sample?.opacity ?? 1, force: sample?.force ?? 1, azimuth: upright ? 0 : .pi / 2, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: drawn?.path.creationDate ?? date))
    }
}
