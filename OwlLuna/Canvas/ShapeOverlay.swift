import UIKit
import PencilKit

/// Lies over the pages while a shape is picked from the strip over the tray: it takes the drags, so the canvases
/// underneath draw nothing, and shows the shape in the pen's ink as it is dragged out.
final class ShapeOverlay: UIView {
    /// Whether a touch at a point should go to what lies under the overlay, such as a selected picture's handles.
    var passesThrough: ((CGPoint) -> Bool)?

    private let outline = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        outline.fillColor = nil
        outline.lineCap = .round
        outline.lineJoin = .round
        layer.addSublayer(outline)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && passesThrough?(point) != true
    }

    /// Shows the shape through `points`, given in this view's own points.
    func show(_ points: [CGPoint], color: UIColor, width: CGFloat) {
        let path = CGMutablePath()
        path.addLines(between: points)
        CATransaction.withoutActions {
            outline.path = path
            outline.strokeColor = color.cgColor
            outline.lineWidth = width
        }
    }

    func clear() {
        outline.path = nil
    }
}

extension ShapeSnap {
    /// A shape drawn with `tool`, in its ink and about as broad as its strokes by hand, from the corner nearest `start`.
    static func stroke(_ shape: SnappedShape, tool: PKInkingTool, startingNear start: CGPoint) -> PKStroke {
        let locations = shape.controlPoints(startingNear: start)
        let size = CGSize(width: pointSize(for: tool), height: pointSize(for: tool))
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: 0.005 * Double(index), size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(tool.inkType, color: tool.color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// PencilKit draws a pen's, fineliner's or fountain pen's nib 2 pt narrower all round than its points: a pen's shape is
    /// drawn as wide as it is set, and never finer than a stroke by hand, and the others at the size a stroke by hand records.
    static func pointSize(for tool: PKInkingTool) -> CGFloat {
        switch tool.inkType {
        case .pen: max(tool.width / 2 + 2, 3)
        case .monoline: tool.width + 2
        case .fountainPen: 2.2 + 0.57 * tool.width
        default: tool.width
        }
    }

    /// How broad a shape drawn with `tool` comes out, for the outline shown while it is dragged.
    static func drawnWidth(for tool: PKInkingTool) -> CGFloat {
        switch tool.inkType {
        case .pen, .monoline, .fountainPen: max(2 * (pointSize(for: tool) - 2), 1)
        default: max(tool.width, 1)
        }
    }
}

/// A shape picked from the strip over the tray, drawn from where a drag starts to where it ends.
enum ShapeKind: String, CaseIterable, Identifiable, Sendable {
    case line, arrow, circle, rectangle, triangle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: String(localized: "Line")
        case .arrow: String(localized: "Arrow")
        case .circle: String(localized: "Circle")
        case .rectangle: String(localized: "Rectangle")
        case .triangle: String(localized: "Triangle")
        }
    }

    var symbol: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .circle: "circle"
        case .rectangle: "rectangle"
        case .triangle: "triangle"
        }
    }

    /// A circle is the ellipse in the drag's box, and a true circle when the box is nearly square. A triangle
    /// stands on the box's foot. An arrow points where the drag ends, its head larger for a wider pen.
    func shape(from a: CGPoint, to b: CGPoint, width: CGFloat = 0) -> SnappedShape {
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch self {
        case .line:
            let (start, end) = ShapeRecognizer.squared(a, b)
            return .line(start, end)
        case .arrow:
            let (tail, tip) = ShapeRecognizer.squared(a, b)
            return .arrow(tail, tip, head: min(14 + 3 * width, ShapeRecognizer.distance(tail, tip) / 3))
        case .circle:
            var radii = CGSize(width: box.width / 2, height: box.height / 2)
            if abs(radii.width - radii.height) < 0.14 * max(radii.width, radii.height) {
                radii = CGSize(width: (radii.width + radii.height) / 2, height: (radii.width + radii.height) / 2)
            }
            return .ellipse(center: CGPoint(x: box.midX, y: box.midY), radii: radii, rotation: 0)
        case .rectangle:
            return .polygon([CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                             CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)])
        case .triangle:
            return .polygon([CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)])
        }
    }
}
