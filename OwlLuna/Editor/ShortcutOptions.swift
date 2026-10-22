import SwiftUI

/// Which shortcuts stand in the tray, as tags: one that is tied on is mustard, with a check mark.
struct ShortcutOptions: View {
    let toolbox: Toolbox
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        // At the largest text sizes the tags are a list, each the whole width, so no name is cut short.
        // At the very largest the card is wider too, or a word as short as "Imagen" is split over two lines.
        let list = textSize.isAccessibilitySize
        let width: CGFloat = textSize > .accessibility2 ? 440 : 328
        let layout = list ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x2)) : AnyLayout(FlowLayout(spacing: Space.x2))
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("Shortcuts in the Tray")
                .font(.headline)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            layout {
                ForEach(ToolExtra.allCases) { extra in
                    let shown = toolbox.extras.contains(extra)
                    ShortcutTag(extra: extra, isShown: shown, fills: list) { toolbox.setExtra(extra, shown: !shown) }
                        .padding(.vertical, -Space.x1)
                        .accessibilityIdentifier("editor.tools.shortcut.\(extra.rawValue)")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                Image(systemName: ToolExtra.shapes.symbol).font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text("Shapes draws a line, arrow, circle, rectangle or triangle where you drag. Or draw one by hand and rest the pen a moment before lifting to straighten it.")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.x3)
            .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
            .accessibilityElement(children: .combine)
        }
        .padding(Space.x4)
        .frame(minWidth: 328, idealWidth: width, maxWidth: width, alignment: .leading)
    }
}

/// A shortcut as a tag: mustard with a check mark while it stands in the tray, plain with a plus while it doesn't.
/// A plain tag is paper by day and a well at night.
private struct ShortcutTag: View {
    let extra: ToolExtra
    let isShown: Bool
    /// The whole width, with the name on as many lines as it needs.
    let fills: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let night = scheme == .dark
        let shape = RoundedRectangle.plate
        Button(action: action) {
            HStack(spacing: Space.x2) {
                Image(systemName: extra.symbol).font(.footnote.weight(.semibold))
                Text(extra.title)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
                Image(systemName: isShown ? "checkmark" : "plus").font(.caption.weight(.bold)).opacity(isShown ? 1 : 0.6)
            }
            .foregroundStyle(isShown ? Color.onMustard : night ? Color.ink : Color.labelInk)
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x1)
            .frame(minHeight: 32)
            .background(isShown ? Color.mustard : ToolSwatch.paper(onDark: false, night: night), in: shape)
            .overlay { shape.strokeBorder(Color.hairline, lineWidth: 1) }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(extra.title)
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : .isButton)
    }
}
