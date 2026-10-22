import SwiftUI

/// Progress as a cobalt thread in a well. With no telling how long, a short thread runs the length of it.
struct ThreadProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View { Thread(configuration: configuration) }

    private struct Thread: View {
        let configuration: Configuration
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var runs = false

        private var isLabelled: Bool { configuration.label != nil || configuration.currentValueLabel != nil }

        /// On its own and with no end in sight it is a short well, where a spinner would have been.
        private var length: CGFloat? {
            guard configuration.fractionCompleted == nil else { return nil }
            if isLabelled { return 220 }
            switch controlSize {
            case .mini, .small: return 28
            case .large, .extraLarge: return 88
            default: return 44
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Space.x2) {
                if isLabelled {
                    HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                        configuration.label
                        Spacer(minLength: 0)
                        configuration.currentValueLabel?.monospacedDigit()
                    }
                    .font(.subheadline)
                }
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.well)
                        if let done = configuration.fractionCompleted {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primaryCloth)
                                .frame(width: max(4, width * min(max(done, 0), 1)))
                                .animation(Motion.quick, value: done)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primaryCloth)
                                .frame(width: width * 0.3)
                                .offset(x: reduceMotion ? width * 0.35 : (runs ? width * 0.7 : 0))
                                .opacity(reduceMotion && !runs ? 0.35 : 1)
                        }
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: length)
            .onAppear {
                guard configuration.fractionCompleted == nil else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { runs = true }
            }
        }
    }
}

extension ProgressViewStyle where Self == ThreadProgressStyle {
    static var thread: ThreadProgressStyle { ThreadProgressStyle() }
}

// MARK: Nothing here

/// What a list or a sheet shows when it has nothing: a plate with its symbol in a small square, a title and a line under it.
struct EmptyPlate<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let message: Text
    @ViewBuilder var actions: Actions

    init(_ title: LocalizedStringKey, systemImage: String, message: Text, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Space.x2) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .plate(in: RoundedRectangle.plate)
                .accessibilityHidden(true)
            Text(title)
                .displayFont(22, relativeTo: .title2)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, Space.x1)
            message
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
            actions.padding(.top, Space.x2)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(Space.x5)
        .plate(in: RoundedRectangle.plate, fill: .board)
        .frame(minWidth: 240, maxWidth: 380)
        .padding(Space.x5)
        .frame(maxWidth: .infinity)
    }
}
