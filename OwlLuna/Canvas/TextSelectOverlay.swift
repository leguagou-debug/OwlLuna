import UIKit

/// Laid over the pages while PDF text is being selected: it takes the touches, and washes what is selected.
/// Rectangles are in stack points, like the ink lasso's.
final class TextSelectOverlay: UIView {
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { redraw() } }
    }

    private let wash = CAShapeLayer()
    private var rects: [CGRect] = []
    /// Where the touch that is now dragging came down: a pan only begins some way on from there.
    private(set) var touchDown: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        wash.lineWidth = 1
        layer.addSublayer(wash)
        colour()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        colour()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        touchDown = touches.first?.location(in: self)
    }

    private func colour() {
        wash.fillColor = tintColor.withAlphaComponent(0.26).cgColor
        wash.strokeColor = tintColor.withAlphaComponent(0.7).cgColor
    }

    func show(_ rects: [CGRect]) {
        self.rects = rects
        redraw()
    }

    private func redraw() {
        let path = CGMutablePath()
        for rect in rects {
            let box = rect.scaled(by: scale).insetBy(dx: -1, dy: 0)
            let corner = min(2, box.width / 2, box.height / 2)
            path.addRoundedRect(in: box, cornerWidth: corner, cornerHeight: corner)
        }
        CATransaction.withoutActions { wash.path = rects.isEmpty ? nil : path }
    }
}
