import SwiftUI

private struct TextSizeCap: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active { content.dynamicTypeSize(...barTextLimit) } else { content }
    }
}

/// A field ruled onto a bar: a glyph, the words, a way to clear them, and room for one more control. Escape clears it, then leaves it.
struct OwlLunaSearchField<Accessory: View>: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var systemImage = "magnifyingglass"
    var isSearch = true
    var clears = true
    var handlesEscape = true
    /// Off for a field outside a bar, whose words grow with the text size.
    var capsTextSize = true
    var identifier: String?
    var focus: FocusState<Bool>.Binding
    @ViewBuilder var accessory: Accessory
    @AccessibilityFocusState private var voiceOverOnField: Bool

    var body: some View {
        HStack(spacing: Space.x2) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.textSecondary)
                .dynamicTypeSize(...barTextLimit)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Color.textSecondary))
                .font(.callout)
                .foregroundStyle(Color.ink)
                .tint(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .focused(focus)
                .accessibilityFocused($voiceOverOnField)
                .accessibilityLabel(Text(prompt))
                .accessibilityAddTraits(isSearch ? .isSearchField : [])
                .accessibilityIdentifier(identifier ?? "", isEnabled: identifier != nil)
            if clears, !text.isEmpty {
                Button {
                    text = ""
                    focus.wrappedValue = true
                    voiceOverOnField = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear Text"))
                .accessibilityIdentifier(identifier.map { "\($0).clear" } ?? "", isEnabled: identifier != nil)
            }
            accessory
        }
        .padding(.leading, Space.x3)
        .padding(.trailing, text.isEmpty ? Space.x3 : 0)
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { focus.wrappedValue = true } }
        .background {
            if handlesEscape, focus.wrappedValue {
                Button("Cancel") { if text.isEmpty { focus.wrappedValue = false } else { text = "" } }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .background { Color.clear.plate(in: RoundedRectangle.plate, fill: .board, focused: focus.wrappedValue).padding(.vertical, BarMetrics.inset) }
        .textInputAutocapitalization(isSearch ? .never : nil)
        .autocorrectionDisabled(isSearch)
        .submitLabel(isSearch ? .search : .go)
        .modifier(TextSizeCap(active: capsTextSize))
        .accessibilityElement(children: .contain)
    }
}

extension OwlLunaSearchField where Accessory == EmptyView {
    init(_ prompt: LocalizedStringKey, text: Binding<String>, systemImage: String = "magnifyingglass", handlesEscape: Bool = true,
         capsTextSize: Bool = true, identifier: String? = nil, focus: FocusState<Bool>.Binding) {
        self.init(prompt: prompt, text: text, systemImage: systemImage, handlesEscape: handlesEscape, capsTextSize: capsTextSize,
                  identifier: identifier, focus: focus) { EmptyView() }
    }
}

extension View {
    /// A text field in a sheet: a rounded well, 44 points tall, outlined in the accent while it has focus. A tap anywhere on it calls `focus`.
    func owlLunaField(focused: Bool = false, focus: @escaping () -> Void = {}) -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(Color.ink)
            .tint(Color.accentColor)
            .padding(.horizontal, Space.x3)
            .frame(minHeight: 44)
            .background { Color.clear.contentShape(Rectangle()).onTapGesture(perform: focus) }
            .well(in: RoundedRectangle.plate, focused: focused)
    }
}
