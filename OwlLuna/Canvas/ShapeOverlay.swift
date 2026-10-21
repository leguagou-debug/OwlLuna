import UIKit

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = path
        outline.strokeColor = color.cgColor
        outline.lineWidth = width
        CATransaction.commit()
    }

    func clear() {
        outline.path = nil
    }
}
