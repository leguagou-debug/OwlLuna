import SwiftUI

struct NoticeBanner: View {
    /// A button beside the message that does what it says and puts the notice away.
    struct Action {
        let title: LocalizedStringKey
        let perform: () -> Void
    }

    let notice: DocumentNotice
    var action: Action?
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let dismissable = notice.kind != .saveFailed
        let stacked = action != nil && dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x2)) : AnyLayout(HStackLayout(spacing: Space.x3))
        layout {
            HStack(spacing: Space.x3) {
                Image(systemName: notice.kind == .saveFailed ? "exclamationmark.icloud" : notice.kind == .newerVersion ? "icloud.and.arrow.down"
                                  : notice.kind == .keptCopy ? "doc.on.doc" : "info.circle")
                    .foregroundStyle(notice.kind == .saveFailed ? Color.tomato : Color.accentColor)
                Text(notice.message).font(.subheadline).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if action != nil || dismissable {
                HStack(spacing: Space.x1) {
                    if let action {
                        Button(action.title) {
                            action.perform()
                            dismiss()
                        }
                        .buttonStyle(.owlLuna(.primary, compact: true))
                    }
                    if dismissable {
                        Button(action: dismiss) { Label("Dismiss", systemImage: "xmark").imageScale(.medium) }
                            .buttonStyle(.barIcon)
                    }
                }
            }
        }
        .padding(.leading, Space.x4)
        .padding(.trailing, dismissable ? Space.x1 : Space.x4)
        .padding(.vertical, dismissable && !stacked ? Space.x1 : Space.x3)
        .frame(maxWidth: 520, alignment: .leading)
        .board(in: RoundedRectangle.bar)
        .padding(.horizontal, Space.x4)
        .accessibilityElement(children: action == nil ? .combine : .contain)
        .accessibilityAddTraits(action == nil ? .isStaticText : [])
    }
}
