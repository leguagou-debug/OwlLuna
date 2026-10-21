import UIKit
import PencilKit

/// Ink as shapes, so a PDF of it is small and sharp at any zoom: the pen, fineliner and fountain pen as the outline their nib
/// sweeps. Other inks go in as pictures in their place among the strokes, the highlighter multiplied in as the screen shows it.
enum InkVectors {
    struct Style: Sendable {
        /// Dark converts the colours as PencilKit does on dark paper.
        var appearance: UIUserInterfaceStyle = .light
        var multipliesHighlighter = true
        /// How finely the inks drawn as pictures are drawn, in pixels a point.
        var pictureScale: CGFloat = 3
    }

    enum Nib { case round, oval }

    /// How far a simplified outline may stray from the nib's path, in points of the page.
    static let tolerance: CGFloat = 0.03

    /// Draws `rect` of the drawing to fill `size` of the context, stroke by stroke in the order they were written.
    static func draw(_ drawing: PKDrawing, from rect: CGRect, in ctx: CGContext, size: CGSize, style: Style = Style()) {
        let factor = size.width / max(rect.width, 1)
        let toPage = CGAffineTransform(translationX: -rect.minX, y: -rect.minY).concatenating(CGAffineTransform(scaleX: factor, y: factor))
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        var run: [PKStroke] = [], multiplies = false
        func flush() {
            guard !run.isEmpty else { return }
            picture(of: run, within: rect, toPage: toPage, in: ctx, scale: style.pictureScale * factor, appearance: style.appearance, multiplies: multiplies)
            run.removeAll()
        }
        for stroke in drawing.strokes where stroke.renderBounds.intersects(rect) {
            if let nib = nib(for: stroke) {
                flush()
                fill(stroke, nib: nib, toPage: toPage, in: ctx, appearance: style.appearance)
            } else {
                let multiplying = style.multipliesHighlighter && stroke.ink.inkType == .marker
                if multiplying != multiplies { flush() }
                multiplies = multiplying
                run.append(stroke)
            }
        }
        flush()
        ctx.restoreGState()
    }

    /// The nib a stroke can be drawn with as a shape, or nil where PencilKit's own picture of it is needed: inks with a grain
    /// or a soft edge, and points whose size or opacity it treats some other way.
    static func nib(for stroke: PKStroke) -> Nib? {
        let nib: Nib
        switch stroke.ink.inkType {
        case .pen, .monoline: nib = .round
        case .fountainPen: nib = .oval
        default: return nil
        }
        for point in stroke.path where abs(point.size.width - point.size.height) > 0.01 || point.opacity < 0.999 { return nil }
        return nib
    }

    /// PencilKit draws a nib two points narrower all round than the size its points are given.
    static func radius(_ point: PKStrokePoint) -> CGFloat { max(point.size.width - 2, 0) }

    /// A point of the nib's path on the page: where it is, how far the nib reaches, and which way it is turned.
    struct Sample {
        var location: CGPoint
        var radius: CGFloat
        var azimuth: CGFloat
    }

    private static func fill(_ stroke: PKStroke, nib: Nib, toPage: CGAffineTransform, in ctx: CGContext, appearance: UIUserInterfaceStyle) {
        var color = stroke.ink.color
        if appearance == .dark { color = PKInkingTool.convertColor(color, from: .light, to: .dark) }
        var alpha: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        // A stroke moved or turned is placed on the page here; one stretched unevenly is drawn through a transform instead.
        let whole = stroke.transform.concatenating(toPage)
        let determinant = whole.a * whole.d - whole.b * whole.c
        let even = determinant > 0 && abs(whole.a - whole.d) < 1e-4 && abs(whole.b + whole.c) < 1e-4
        let placed = even ? whole : .identity, scale = even ? sqrt(determinant) : 1, turn = even ? atan2(whole.b, whole.a) : 0
        let interpolated = Array(stroke.path.interpolatedPoints(by: .distance(0.5)))
        let samples = (interpolated.isEmpty ? Array(stroke.path) : interpolated).map { point in
            Sample(location: rounded(point.location.applying(placed)), radius: radius(point) * scale, azimuth: point.azimuth + turn)
        }
        guard !samples.isEmpty else { return }
        let isolated = !even || stroke.mask != nil || alpha < 1
        if isolated { ctx.saveGState() }
        if !even { ctx.concatenate(whole) }
        if let mask = stroke.mask {
            var maskTransform = placed
            if let path = mask.cgPath.copy(using: &maskTransform) { ctx.addPath(path) }
            ctx.clip()
        }
        if alpha < 1 {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            color = color.withAlphaComponent(1)
        }
        let tolerance = Self.tolerance / scale
        switch nib {
        case .round: round(samples, color: color.cgColor, tolerance: tolerance, dot: stroke.path.count == 1, in: ctx)
        case .oval: oval(samples, color: color.cgColor, tolerance: tolerance, in: ctx)
        }
        if alpha < 1 { ctx.endTransparencyLayer() }
        if isolated { ctx.restoreGState() }
    }

    private static func rounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x * 100).rounded() / 100, y: (point.y * 100).rounded() / 100)
    }

    /// Runs of segments as wide as one another are one line with round ends and joins. PencilKit draws a single point as a dot,
    /// and several in one place as nothing.
    private static func round(_ samples: [Sample], color: CGColor, tolerance: CGFloat, dot: Bool, in ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let start = samples[0].location
        if samples.allSatisfy({ abs($0.location.x - start.x) < 0.01 && abs($0.location.y - start.y) < 0.01 }) {
            let r = samples.map(\.radius).max() ?? 0
            if dot, r > 0 { ctx.fillEllipse(in: CGRect(x: start.x - r, y: start.y - r, width: 2 * r, height: 2 * r)) }
            return
        }
        var first = 0
        while first < samples.count - 1 {
            let width = samples[first].radius + samples[first + 1].radius
            var last = first + 1
            while last + 1 < samples.count, abs(samples[last].radius + samples[last + 1].radius - width) <= max(0.03, width * 0.03) { last += 1 }
            if width > 0 {
                let kept = simplified(samples, first, last, tolerance: tolerance)
                ctx.setLineWidth(width)
                ctx.addLines(between: kept.map { samples[$0].location })
                ctx.strokePath()
            }
            first = last
        }
    }

    /// Each step of the nib is the hull of the oval where it starts and where it ends; together they make the stroke.
    private static func oval(_ samples: [Sample], color: CGColor, tolerance: CGFloat, in ctx: CGContext) {
        let path = CGMutablePath()
        let kept = simplified(samples, 0, samples.count - 1, tolerance: tolerance)
        var previous = ellipse(samples[kept[0]], tolerance: tolerance)
        if kept.count == 1, previous.count > 2 { path.addLines(between: convexHull(previous)) }
        for index in kept.dropFirst() {
            let next = ellipse(samples[index], tolerance: tolerance)
            let hull = convexHull(previous + next)
            if hull.count > 2 {
                path.addLines(between: hull)
                path.closeSubpath()
            }
            previous = next
        }
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
    }

    /// The samples a straight run of the nib can skip: where the path, the nib's reach and its turn all change evenly.
    static func simplified(_ samples: [Sample], _ first: Int, _ last: Int, tolerance: CGFloat) -> [Int] {
        guard last - first > 1 else { return first == last ? [first] : [first, last] }
        var keep = [first, last], stack = [(first, last)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let p = samples[a], q = samples[b]
            let dx = q.location.x - p.location.x, dy = q.location.y - p.location.y, length2 = dx * dx + dy * dy
            var worst: CGFloat = 0, at = -1
            for index in (a + 1)..<b {
                let s = samples[index]
                let t = length2 > 0 ? min(max(((s.location.x - p.location.x) * dx + (s.location.y - p.location.y) * dy) / length2, 0), 1) : 0
                let x = p.location.x + dx * t, y = p.location.y + dy * t
                let off = hypot(s.location.x - x, s.location.y - y)
                let reach = abs(s.radius - (p.radius + (q.radius - p.radius) * t))
                let turn = abs(s.azimuth - (p.azimuth + (q.azimuth - p.azimuth) * t)) * s.radius
                let error = max(off, reach, turn)
                if error > worst { (worst, at) = (error, index) }
            }
            if worst > tolerance, at >= 0 {
                keep.append(at)
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        return keep.sorted()
    }

    /// The fountain pen's nib: a quarter as thick as it is long, turned to the Pencil's azimuth.
    private static func ellipse(_ sample: Sample, tolerance: CGFloat) -> [CGPoint] {
        let a = sample.radius, b = a / 4
        guard a > 0 else { return [sample.location] }
        let sides = Int(min(max((CGFloat.pi / acos(max(1 - tolerance / a, -1))).rounded(.up), 8), 64))
        let c = cos(sample.azimuth), s = sin(sample.azimuth)
        return (0..<sides).map { index in
            let t = CGFloat(index) / CGFloat(sides) * 2 * .pi
            let x = a * cos(t), y = b * sin(t)
            return rounded(CGPoint(x: sample.location.x + x * c - y * s, y: sample.location.y + x * s + y * c))
        }
    }

    /// Counter-clockwise, so every hull winds the same way and their union fills.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func picture(of strokes: [PKStroke], within rect: CGRect, toPage: CGAffineTransform, in ctx: CGContext, scale: CGFloat,
                                appearance: UIUserInterfaceStyle, multiplies: Bool) {
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -2, dy: -2).integral.intersection(rect)
        guard !bounds.isNull, !bounds.isEmpty else { return }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: appearance).performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: bounds, scale: Whiteboard.scale(for: bounds.size, wanted: scale))
        }
        guard let image else { return }
        UIGraphicsPushContext(ctx)
        image.draw(in: bounds.applying(toPage), blendMode: multiplies ? .multiply : .normal, alpha: 1)
        UIGraphicsPopContext()
    }
}
