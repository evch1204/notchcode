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
            .font(Theme.Fonts.keycap)
            .foregroundStyle(onLight ? Theme.Colors.keycapTextOnLight : Theme.Colors.inkSecondary)
            .padding(.horizontal, Theme.Size.keycapHPadding)
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
    var onLight = false
    @Environment(\.inlineKeycaps) private var shows

    init(_ label: String, onLight: Bool = false) {
        self.label = label
        self.onLight = onLight
    }

    var body: some View {
        if shows {
            Keycap(label, onLight: onLight)
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
