// SettingsPage.swift
// Settings as a page inside the card (the gear in the strip, or ⌘,). Never a
// separate window. Compact rows in inset groups, scrollable, "‹ Back" (or esc)
// returns to the tab it came from. Every control writes straight into
// AppState.prefs, which saves itself.

import SwiftUI

@MainActor
struct SettingsPage: View {
    @ObservedObject var state: AppState

    @State private var hookStatus: HooksInstaller.Status = .notConnected
    @State private var hookError: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
            HStack(spacing: Theme.Size.spaceM) {
                Button {
                    state.closeSettings()
                } label: {
                    HStack(spacing: Theme.Size.spaceS) {
                        Image(systemName: Theme.Symbols.back)
                            .font(Theme.Fonts.chevron)
                        Text("Back")
                    }
                }
                .buttonStyle(SmallPillStyle())
                InlineKeycap(Theme.Keys.escape)
                Spacer(minLength: Theme.Size.spaceM)
                Text("Settings")
                    .font(Theme.Fonts.bodySemibold)
                    .foregroundStyle(Theme.Colors.ink)
                Spacer(minLength: Theme.Size.spaceM)
                InlineKeycap(Theme.Keys.settings)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Size.settingsGroupSpacing) {
                    connectGroup

                    SettingsGroup(title: "When idle") {
                        SettingsRow(label: "Notch") {
                            SegmentedPills(selection: $state.prefs.idleStyle, options: [
                                (.wings, "Resting row"),
                                (.closed, "Pure notch"),
                            ])
                        }
                    }

                    SettingsGroup(title: "When Claude needs you") {
                        SettingsRow(label: "Style") {
                            SegmentedPills(selection: $state.prefs.attentionStyle, options: [
                                (.twoRow, "Two rows"),
                                (.wings, "Wings only"),
                            ])
                        }
                        SettingsRow(label: "Also post a macOS notification") {
                            SmallSwitch(isOn: $state.prefs.systemNotifications)
                        }
                    }

                    SettingsGroup(title: "Passive events") {
                        SettingsRow(label: "Peek when a turn or subagent finishes") {
                            SmallSwitch(isOn: $state.prefs.showPeeks)
                        }
                        SettingsRow(label: "Also peek each file edit", enabled: state.prefs.showPeeks) {
                            SmallSwitch(isOn: $state.prefs.peekEdits)
                                .opacity(state.prefs.showPeeks ? 1 : Theme.Opacity.disabled)
                                .disabled(!state.prefs.showPeeks)
                        }
                        SettingsRow(label: "Peek length", enabled: state.prefs.showPeeks) {
                            KeycapStepper(
                                value: $state.prefs.peekSeconds,
                                range: Theme.Timing.peekSecondsRange,
                                step: Theme.Timing.peekSecondsStep,
                                text: { "\(Int($0)) s" },
                                enabled: state.prefs.showPeeks
                            )
                        }
                    }

                    SettingsGroup(title: "Opening") {
                        SettingsRow(label: "Open the card on") {
                            SegmentedPills(selection: $state.prefs.openGesture, options: [
                                (.click, "Click"),
                                (.hover, "Hover"),
                            ])
                        }
                    }

                    SettingsGroup(title: "Keys") {
                        SettingsRow(label: "\(Theme.Keys.option) space opens the notch from anywhere") {
                            SmallSwitch(isOn: $state.prefs.hotkeyEnabled)
                        }
                        SettingsRow(label: "Show keys beside buttons in the card") {
                            SmallSwitch(isOn: $state.prefs.keycapsBesideButtons)
                        }
                    }

                    SettingsGroup(title: "Agents") {
                        SettingsRow(label: "Show the running agent count beside the closed notch") {
                            SmallSwitch(isOn: $state.prefs.showAgentsInWings)
                        }
                    }

                    SettingsGroup(title: "Usage") {
                        SettingsRow(label: "Refresh plan limits with the claude command") {
                            SmallSwitch(isOn: $state.prefs.planUsageRefresh)
                        }
                        Text("Runs `claude -p /usage` every 15 minutes with no hooks and no model turn; the Fable week and the limits breakdown come from it. Off, the page shows what the status line and Claude Code's own cache last reported.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, Theme.Size.settingsLabelSpacing)
                    }

                    SettingsGroup(title: "Quit") {
                        SettingsRow(label: "Quit notchcode. Relaunch it with scripts/dev.sh, or it starts with your next Claude Code session when the plugin is installed.") {
                            Button("Quit") { state.quit() }
                                .buttonStyle(SmallPillStyle(primary: false))
                                .keyboardShortcut("q", modifiers: .command)
                                .help("⌘Q while the card is open")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: refreshStatus)
    }

    // MARK: Connect

    private var connectGroup: some View {
        SettingsGroup(title: "Connect") {
            HStack(spacing: Theme.Size.spaceM) {
                Circle()
                    .fill(statusColor)
                    .frame(width: Theme.Size.dot, height: Theme.Size.dot)
                Text(statusText)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: Theme.Size.spaceM)
                Button(connectButtonTitle) {
                    toggleConnection()
                }
                .buttonStyle(SmallPillStyle(primary: hookStatus != .connected))
                .disabled(working)
            }
            .frame(minHeight: Theme.Size.settingsRowHeight)
            VStack(alignment: .leading, spacing: Theme.Size.settingsLabelSpacing) {
                Text(HooksInstaller.settingsPath)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Adds our hooks beside your own. Your other hooks are never changed. New Claude Code sessions pick this up; running ones keep their old hooks.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hookError {
                    Text(hookError)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.settingsError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusText: String {
        switch hookStatus {
        case .connected: return "Connected to Claude Code"
        case .notConnected: return "Not connected"
        case .partial: return "Partly connected"
        case .stale: return "Reconnect · the hooks point at an old copy"
        }
    }

    private var connectButtonTitle: String {
        switch hookStatus {
        case .connected: return "Disconnect"
        case .stale: return "Reconnect"
        case .notConnected, .partial: return "Connect"
        }
    }

    private var statusColor: Color {
        switch hookStatus {
        case .connected: return Theme.Colors.settingsConnected
        case .notConnected: return Theme.Colors.settingsDisconnected
        case .partial, .stale: return Theme.Colors.settingsPartial
        }
    }

    private func refreshStatus() {
        hookStatus = HooksInstaller.status()
    }

    private func toggleConnection() {
        working = true
        defer {
            working = false
            refreshStatus()
        }
        do {
            // "Partly connected" connects the rest; stale ("Reconnect") rewrites ours to the bin copies.
            if hookStatus == .connected {
                try HooksInstaller.disconnect()
            } else {
                try HooksInstaller.connect()
            }
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }
}

// MARK: - Settings building blocks

/// A caption title over an inset group of rows.
@MainActor
private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.settingsLabelSpacing) {
            Text(title)
                .font(Theme.Fonts.captionMedium)
                .foregroundStyle(Theme.Colors.inkTertiary)
                .padding(.leading, Theme.Size.insetPadding)
            InsetGroup {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
            }
        }
    }
}

/// Label on the left, control on the right.
@MainActor
private struct SettingsRow<Control: View>: View {
    let label: String
    var enabled = true
    let control: Control

    init(label: String, enabled: Bool = true, @ViewBuilder control: () -> Control) {
        self.label = label
        self.enabled = enabled
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(enabled ? Theme.Colors.ink : Theme.Colors.inkTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Size.spaceM)
            control
                .fixedSize()
        }
        .frame(minHeight: Theme.Size.settingsRowHeight)
    }
}
