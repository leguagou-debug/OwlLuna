import SwiftUI

/// Controls are bound like the notebooks: boards stand on the desk, wells are pressed into it, plates are ruled onto a bar,
/// and the finishing action is cloth.
enum Elevation {
    /// Shadows on the desk are a warm umber by day and plain black at night.
    static func shade(_ dark: Bool) -> Color { dark ? .black : umber }
    private static let umber = Color(hex: 0x2A2116)
}

/// The covers' two-way weave at the shelf cover's scale, for filled buttons.
@MainActor
enum ClothWeave {
    static let tile: Image = {
        let format = UIGraphicsImageRendererFormat(scale: 3)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            let ctx = context.cgContext
            ctx.setLineWidth(2)
            for (alpha, white, rising) in [(0.06, 1.0, true), (0.07, 0.0, false)] {
                ctx.setStrokeColor(UIColor(white: white, alpha: alpha).cgColor)
                for x in stride(from: -4.0, through: 4.0, by: 4.0) {
                    ctx.move(to: CGPoint(x: rising ? x - 1 : x + 5, y: -1))
                    ctx.addLine(to: CGPoint(x: rising ? x + 5 : x - 1, y: 5))
                }
                ctx.strokePath()
            }
        }
        return Image(uiImage: image)
    }()

    /// The edge round a piece of cloth: lit along its top, shaded along its foot.
    static let bevel = LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0), .black.opacity(0.20)],
                                      startPoint: .top, endPoint: .bottom)
}

private struct ClothWeaveOverlay<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay { if contrast != .increased { shape.fill(ImagePaint(image: ClothWeave.tile, scale: 1)) } }
    }
}

extension View {
    /// Lays the cloth's weave over this view in `shape`, unless Increase Contrast is on.
    func clothWeave<S: Shape>(in shape: S) -> some View {
        modifier(ClothWeaveOverlay(shape: shape))
    }
}

private struct BoardSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var pressed = false
    var flat = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let dark = scheme == .dark, raised = !pressed && !flat
        content
            .background {
                shape.fill(Color.board.opacity(flat ? 0.5 : 1))
                    .overlay { if pressed { shape.fill(Color.well) } }
                    .shadow(color: Elevation.shade(dark).opacity(raised ? (dark ? 0.40 : 0.10) : 0), radius: 0.5, y: 0.5)
                    .shadow(color: Elevation.shade(dark).opacity(raised ? (dark ? 0.22 : 0.07) : 0), radius: 6, y: 3)
            }
            .overlay {
                if contrast != .increased, raised {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.09 : 0.85), .white.opacity(0)],
                                                      startPoint: .top, endPoint: .center), lineWidth: 1)
                        .padding(1)
                        .allowsHitTesting(false)
                }
            }
            .overlay { if !flat { shape.strokeBorder(Color.hairline, lineWidth: 1).allowsHitTesting(false) } }
    }
}

private struct WellSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var focused = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let dark = scheme == .dark, increased = contrast == .increased
        content
            .background {
                shape.fill(Color.well.shadow(.inner(color: Elevation.shade(dark).opacity(dark ? 0.6 : 0.16), radius: 1.5, y: 1)))
            }
            .overlay {
                if !increased {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0), .white.opacity(dark ? 0.06 : 0.7)],
                                                      startPoint: .center, endPoint: .bottom), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.strokeBorder(focused ? Color.accentColor : (increased ? Color.ink.opacity(0.5) : Color.hairline),
                                   lineWidth: focused ? (increased ? 2 : 1.5) : 1)
                    .allowsHitTesting(false)
            }
            .animation(Motion.quick, value: focused)
    }
}

func plateEdge(_ contrast: ColorSchemeContrast, flat: Bool = false) -> Color {
    Color.ink.opacity(flat ? 0.18 : (contrast == .increased ? 0.7 : 0.35))
}

private struct PlateSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: Color = .clear
    var pressed = false
    var focused = false
    var flat = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background { shape.fill(fill).overlay { if pressed { shape.fill(Color.well) } } }
            .overlay {
                shape.strokeBorder(focused ? Color.accentColor : plateEdge(contrast, flat: flat),
                                   lineWidth: focused ? (contrast == .increased ? 2 : 1.5) : 1)
                    .allowsHitTesting(false)
            }
            .animation(Motion.quick, value: focused)
    }
}

extension RoundedRectangle {
    static let plate = RoundedRectangle(cornerRadius: Radius.plate, style: .continuous)
    static let thumb = RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous)
    static let track = RoundedRectangle(cornerRadius: Radius.track, style: .continuous)
    static let bar = RoundedRectangle(cornerRadius: Radius.bar, style: .continuous)
}

extension View {
    /// A flat panel ruled in ink, with nothing under it unless it is given a fill: what a bar's controls are cut from.
    func plate<S: InsettableShape>(in shape: S, fill: Color = .clear, pressed: Bool = false, focused: Bool = false,
                                   flat: Bool = false) -> some View {
        modifier(PlateSurface(shape: shape, fill: fill, pressed: pressed, focused: focused, flat: flat))
    }

    /// A raised Board panel with a Hairline edge, a lit top edge and a soft umber shadow.
    func board<S: InsettableShape>(in shape: S, pressed: Bool = false, flat: Bool = false) -> some View {
        modifier(BoardSurface(shape: shape, pressed: pressed, flat: flat))
    }

    /// A recessed panel for things that take input: text fields and segment tracks.
    func well<S: InsettableShape>(in shape: S, focused: Bool = false) -> some View {
        modifier(WellSurface(shape: shape, focused: focused))
    }
}

/// Bars stay one height: their controls stop growing at the largest standard size and show the Large Content Viewer instead.
let barTextLimit = DynamicTypeSize.xxxLarge

/// A bar's controls are drawn 40 points tall and touched at 44.
enum BarMetrics {
    static let height: CGFloat = 40
    static let inset: CGFloat = 2
}

struct BarLimit: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.dynamicTypeSize(...barTextLimit).accessibilityShowsLargeContentViewer()
        } else {
            content
        }
    }
}
