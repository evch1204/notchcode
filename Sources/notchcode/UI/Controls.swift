// Controls.swift
// The small controls the tools share: segmented pills (Settings, the Files preview),
// the small switch and the keycap stepper (Settings), the small pill style (Settings,
// Files), the tree toggle pill (Files, Git, Changes) and the small tag (Sessions, the
// Git branch picker).

import SwiftUI

/// A picker as a row of pills in a capsule track.
@MainActor
struct SegmentedPills<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { item in
                let selected = item.element.0 == selection
                Button {
                    withAnimation(Theme.Motion.tap) { selection = item.element.0 }
                } label: {
                    Text(item.element.1)
                        .font(Theme.Fonts.captionMedium)
                        .foregroundStyle(selected ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Size.pickerHPadding)
                        .frame(height: Theme.Size.pickerHeight - 2 * Theme.Size.pickerInset)
                        .background(Capsule(style: .continuous).fill(selected ? Theme.Colors.pickerSelected : Color.clear))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Size.pickerInset)
        .background(Capsule(style: .continuous).fill(Theme.Colors.pickerTrack))
    }
}

/// A small on/off switch.
@MainActor
struct SmallSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(Theme.Motion.tap) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? Theme.Colors.switchOn : Theme.Colors.switchOff)
                Circle()
                    .fill(Theme.Colors.switchKnob)
                    .padding(Theme.Size.switchKnobInset)
            }
            .frame(width: Theme.Size.switchWidth, height: Theme.Size.switchHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// − value + with keycap buttons.
@MainActor
struct KeycapStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String
    var enabled = true

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Keycap(Theme.Glyphs.minus)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || value <= range.lowerBound)

            Text(text(value))
                .font(Theme.Fonts.captionMedium)
                .foregroundStyle(Theme.Colors.ink)
                .frame(width: Theme.Size.stepperValueWidth)

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Keycap(Theme.Keys.plus)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || value >= range.upperBound)
        }
        .opacity(enabled ? 1 : Theme.Opacity.disabled)
    }
}

/// Compact capsule button: white when primary, ghost otherwise.
@MainActor
struct SmallPillStyle: ButtonStyle {
    var primary = false

    /// A capsule segment: the same press and fill behaviour as the strip's segments.
    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(
            label: configuration.label
                .font(Theme.Fonts.captionMedium)
                .foregroundStyle(primary ? Theme.Colors.primaryText : Theme.Colors.ink)
                .padding(.horizontal, Theme.Size.backPillHPadding)
                .frame(height: Theme.Size.backPillHeight),
            pressed: configuration.isPressed,
            fill: primary ? Theme.Colors.primaryFill : Theme.Colors.ghostFill,
            capsule: true
        )
    }
}

/// The sidebar pill and its ⌘B keycap. Disabled (dimmed) with no file open. The Git tool
/// hides its file list with it.
@MainActor
struct TreeTogglePill: View {
    let collapsed: Bool
    let enabled: Bool
    /// What the pill hides: "file tree" (Files), "file list" (Git).
    var subject = "file tree"
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Button(action: action) {
                Image(systemName: Theme.Symbols.sidebar)
                    .font(Theme.Fonts.symbol(Theme.Fonts.tinySize))
            }
            .buttonStyle(SmallPillStyle())
            .help(collapsed ? "Show the " + subject : "Hide the " + subject)
            InlineKeycap(Theme.Keys.toggleTree)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.Opacity.disabled)
        .fixedSize()
    }
}

/// A small capsule: "Showing", "newest", or the permission mode ("bypass" in clay).
@MainActor
struct SmallTag: View {
    let text: String
    var color: Color = Theme.Colors.inkTertiary

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(color)
            .capsuleTag()
            .fixedSize()
    }
}
