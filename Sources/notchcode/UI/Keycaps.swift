// Keycaps.swift
// Keycaps: the boxed key, the inline keycap in running text, and the footer's key hints.

import SwiftUI

// MARK: - Keycap

@MainActor
struct Keycap: View {
    let label: String
    var onLight = false

    init(_ label: String, onLight: Bool = false) {
        self.label = label
        self.onLight = onLight
    }

    var body: some View {
        Text(label)
            .keycapLabel(onLight: onLight)
            .keycapBox(onLight: onLight)
    }
}

/// A keycap whose label flips like a clock digit when it changes (the sync pill's P → ⏎ and
/// back): the old label turns away around the x axis (0° → −90°, ease-in), then the new one
/// turns in from +90° (ease-out), `Theme.Motion.keycapFlipDuration` each, while the box stays
/// put. Reduce Motion: a crossfade. Everywhere else uses the plain `Keycap`.
@MainActor
struct KeycapFlip: View {
    let label: String
    var onLight = false

    init(_ label: String, onLight: Bool = false) {
        self.label = label
        self.onLight = onLight
    }

    var body: some View {
        ZStack {
            Text(label)
                .keycapLabel(onLight: onLight)
                .id(label)
                .transition(Self.flip)
        }
        .keycapBox(onLight: onLight)
    }

    /// Out to −90° and in from +90°, one after the other.
    @MainActor static var flip: AnyTransition {
        if Theme.Motion.reduceMotion { return AnyTransition.opacity.animation(Theme.Motion.reduced) }
        let duration = Theme.Motion.keycapFlipDuration
        let angle = Theme.Motion.keycapFlipAngle
        return .asymmetric(
            insertion: AnyTransition.modifier(active: FlipTurn(degrees: angle), identity: FlipTurn(degrees: 0))
                .animation(.easeOut(duration: duration).delay(duration)),
            removal: AnyTransition.modifier(active: FlipTurn(degrees: -angle), identity: FlipTurn(degrees: 0))
                .animation(.easeIn(duration: duration))
        )
    }
}

/// A label turned around the x axis; edge-on (±90°) it is gone.
private struct FlipTurn: ViewModifier {
    let degrees: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(degrees), axis: (1, 0, 0), anchor: .center, perspective: Theme.Motion.keycapFlipPerspective)
            .opacity(abs(degrees) >= Theme.Motion.keycapFlipAngle ? 0 : 1)
    }
}

private extension View {
    func keycapLabel(onLight: Bool) -> some View {
        font(Theme.Fonts.keycap)
            .foregroundStyle(onLight ? Theme.Colors.keycapTextOnLight : Theme.Colors.inkSecondary)
    }

    func keycapBox(onLight: Bool) -> some View {
        padding(.horizontal, Theme.Size.keycapHPadding)
            .frame(minWidth: Theme.Size.keycapMin, minHeight: Theme.Size.keycapMin)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
                    .fill(onLight ? Theme.Colors.keycapFillOnLight : Theme.Colors.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.keycap, style: .continuous)
                    .strokeBorder(onLight ? Color.clear : Theme.Colors.hairline, lineWidth: Theme.Size.hairline)
            )
    }
}

/// A keycap beside a button inside the card; hidden by the Settings switch. The footer and
/// the attention row use Keycap directly.
struct InlineKeycap: View {
    let label: String
    @Environment(\.inlineKeycaps) private var shows

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        if shows {
            Keycap(label)
        }
    }
}

private struct InlineKeycapsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether `InlineKeycap`s show; set once on the card's well from Settings.
    var inlineKeycaps: Bool {
        get { self[InlineKeycapsKey.self] }
        set { self[InlineKeycapsKey.self] = newValue }
    }
}

/// One keycap and what it does, for the card's footer.
struct KeyHint {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }
}

/// "⏎ open  Y copy path:line": keycaps with their tertiary labels, never truncated.
@MainActor
struct KeyHints: View {
    let hints: [KeyHint]

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            ForEach(Array(hints.enumerated()), id: \.offset) { item in
                Keycap(item.element.key)
                Text(item.element.label)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }
        }
        .fixedSize()
    }
}

// Another test change for the commit form: delete this line too.
