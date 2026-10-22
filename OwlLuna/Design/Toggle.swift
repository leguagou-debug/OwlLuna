import SwiftUI

/// A switch cut square: a well for a track, cobalt cloth with an accent edge once it is on, and a knob that slides across.
struct OwlLunaToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.labelsVisibility) private var labels

        var body: some View {
            HStack(spacing: Space.x3) {
                if labels != .hidden {
                    configuration.label
                        .foregroundStyle(isEnabled ? Color.ink : Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { configuration.isOn.toggle() } label: { EmptyView() }
                    .buttonStyle(Slab(isOn: configuration.isOn))
            }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
        }
    }

    private struct Slab: ButtonStyle {
        let isOn: Bool

        func makeBody(configuration: Configuration) -> some View {
            SlabBody(isOn: isOn, pressed: configuration.isPressed)
        }
    }

    private struct SlabBody: View {
        let isOn: Bool
        let pressed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

        private let track = RoundedRectangle.track
        private let knob = RoundedRectangle.thumb

        var body: some View {
            Color.clear
                .frame(width: 54, height: 30)
                .background(Color.well, in: track)
                .well(in: track)
                .overlay { cloth.opacity(isOn ? 1 : 0) }
                .overlay { if differentiate || UIAccessibility.isOnOffSwitchLabelsEnabled { marks } }
                .overlay(alignment: isOn ? .trailing : .leading) { knobView.padding(3) }
                .opacity(isEnabled ? 1 : 0.5)
                .frame(minWidth: 54, minHeight: 44)
                .contentShape(Rectangle())
                .contentShape(.hoverEffect, track)
                .hoverEffect(.highlight)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84), value: isOn)
                .animation(reduceMotion ? nil : Motion.quick, value: pressed)
        }

        private var cloth: some View {
            track.fill(Color.primaryCloth)
                .clothWeave(in: track)
                .overlay { track.strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 2 : 1.5) }
        }

        private var knobView: some View {
            let dark = scheme == .dark, increased = contrast == .increased
            let fill = dark ? (isOn ? Color.onPrimaryCloth : Color.board.mix(with: .ink, by: 0.32)) : Color.board
            return knob.fill(fill)
                .overlay {
                    if !increased {
                        knob.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.14 : 0.85), .white.opacity(0)],
                                                         startPoint: .top, endPoint: .center), lineWidth: 1)
                    }
                }
                .overlay { knob.strokeBorder(increased ? Color.inkSecondary : Color.hairline, lineWidth: 1) }
                .shadow(color: Elevation.shade(dark).opacity(isEnabled ? (dark ? 0.45 : 0.18) : 0), radius: 1, y: 1)
                .frame(width: pressed && isEnabled ? 29 : 24, height: 24)
        }

        /// The system's On/Off Labels: a bar where the knob left, a ring where it will go.
        private var marks: some View {
            HStack {
                Capsule().fill(Color.onPrimaryCloth).frame(width: 2, height: 10).opacity(isOn ? 1 : 0)
                Spacer()
                Circle().strokeBorder(Color.textSecondary, lineWidth: 1.5).frame(width: 9, height: 9).opacity(isOn ? 0 : 1)
            }
            .padding(.leading, 13)
            .padding(.trailing, 9)
        }
    }
}

extension ToggleStyle where Self == OwlLunaToggleStyle {
    static var owlLuna: OwlLunaToggleStyle { OwlLunaToggleStyle() }
}
