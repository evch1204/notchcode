// CardView.swift
// The open panel. The strip stays on top as the toolbar (status on the left, the
// tools with the selected one filled on the right, the gear after a rule). Under
// it, a hairline with a short bridge beneath the selected tool, then the content
// well: a request, a question, Settings, or the selected tool's pane. The footer
// under the well carries the keys for that tool. Switching tools glides the fill,
// slides the bridge, re-targets the panel's height, and slides the pane toward
// its new anchor with parallax. What shows is `AppState.cardContent`, one switch
// per place.

import SwiftUI

@MainActor
struct CardView: View {
    @ObservedObject var state: AppState
    let bodySize: CGSize

    private var contentHeight: CGFloat { bodySize.height - state.layout.notchHeight }

    var body: some View {
        let content = state.cardContent
        VStack(spacing: 0) {
            strip
                .riseIn(0)

            VStack(alignment: .leading, spacing: Theme.Size.spaceM) {
                Rectangle()
                    .fill(Theme.Colors.stripDivider)
                    .frame(height: Theme.Size.hairline)
                    .frame(height: Theme.Size.bridgeHeight, alignment: .top)
                    .riseIn(0)

                well(content)
                    .riseIn(1)

                footer(content)
                    .riseIn(2)
            }
            .padding(.horizontal, Theme.Size.sidePadding)
            .padding(.bottom, Theme.Size.sidePadding)
            .frame(width: bodySize.width, height: contentHeight, alignment: .top)
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
        // The bridge and the tool name hang from the tools the strip measured, so they sit
        // under the icons whatever the card's width.
        .overlayPreferenceValue(ToolAnchorsKey.self) { anchors in
            ToolHangers(state: state, content: content, anchors: anchors, dividerY: state.layout.notchHeight)
        }
    }

    // MARK: Strip

    private var strip: some View {
        let session = state.focusedSession
        let shown: SessionState = state.currentPending != nil ? .needsYou : (session.map { state.shownState($0) } ?? .idle)
        return WingRow(layout: state.layout, bodyWidth: bodySize.width) {
            StatusSegment(state: state, session: session, shown: shown)
        } right: {
            StripRightWing(state: state)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.closeCard() }
    }

    // MARK: Well

    /// The content well: what a window shows under its toolbar.
    private func well(_ content: CardContent) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
        return Group {
            switch content {
            case .request(let request):
                if request.kind == .commit {
                    CommitCard(state: state, request: request)
                } else {
                    PermissionCard(state: state, request: request)
                }
            case .question(let question):
                QuestionCard(state: state, question: question)
            case .settings:
                SettingsPage(state: state)
            case .tool:
                tabPanes
            }
        }
        .padding(Theme.Size.wellPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(shape.fill(Theme.Colors.well))
        .overlay(shape.strokeBorder(Theme.Colors.wellStroke, lineWidth: Theme.Size.hairline))
        .clipShape(shape)
        .environment(\.inlineKeycaps, state.prefs.keycapsBesideButtons)
    }

    /// The tool's pane, sliding a short way toward its anchor when the tool changes. The pane's
    /// offset reaches its inset groups through `PaneParallax`, so they move a little further.
    /// Reduce Motion: a crossfade.
    private var tabPanes: some View {
        ZStack(alignment: .top) {
            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(state.paneTab)
                .transition(paneTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private var paneTransition: AnyTransition {
        if Theme.Motion.reduceMotion {
            return AnyTransition.opacity.animation(Theme.Motion.reduced)
        }
        let dx = state.tabMovedForward ? Theme.Motion.paneSlide : -Theme.Motion.paneSlide
        return .asymmetric(
            insertion: Theme.Motion.slide(dx).animation(Theme.Motion.tabIn),
            removal: Theme.Motion.slide(-dx).animation(Theme.Motion.tabOut)
        )
    }

    @ViewBuilder
    private var tabBody: some View {
        switch state.paneTab {
        case .files:
            FilesTab(state: state)
        case .usage:
            UsageTab(state: state)
        case .git:
            GitTab(state: state)
        case .sessions:
            SessionsTab(state: state)
        case .changes, .settings:
            ChangesTab(state: state)
        }
    }

    // MARK: Footer

    private func footer(_ content: CardContent) -> some View {
        HStack(spacing: Theme.Size.spaceM) {
            if let hint = state.hint {
                HintText(text: hint)
            } else {
                KeyHints(hints: keyHints(content))
                if case .tool(.sessions) = content {
                    Text(footerCounts)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Size.spaceM)
            footerMeter
            KeyHints(hints: [KeyHint(Theme.Keys.escape, escapeLabel(content))])
        }
        .frame(height: Theme.Size.cardFooterHeight)
    }

    /// What esc does: "back" out of Settings, the Git tool's dropdown, filter and picker
    /// layers, else "close".
    private func escapeLabel(_ content: CardContent) -> String {
        if isSettings(content) { return "back" }
        if case .tool(.git) = content, let label = state.gitEscapeLabel { return label }
        return "close"
    }

    private func isSettings(_ content: CardContent) -> Bool {
        if case .settings = content { return true }
        return false
    }

    /// The keys for what the well shows.
    private func keyHints(_ content: CardContent) -> [KeyHint] {
        switch content {
        case .request(let request):
            let middle = request.kind.actions.middle
            var hints = [KeyHint(middle.key ?? "", middle.title.lowercased())]
            if request.files.contains(where: { !AppState.diffLines($0).isEmpty }) {
                hints.append(KeyHint(Theme.Keys.diff, "diff"))
            }
            return hints
        case .settings:
            return [KeyHint(Theme.Keys.settings, "toggles this page")]
        case .tool(.changes):
            return [KeyHint(Theme.Keys.enter, "open"), KeyHint(Theme.Keys.copy, "copy path:line")]
        case .tool(.files):
            return [
                KeyHint(Theme.Keys.enter, "open"),
                KeyHint(Theme.Keys.slash, "filter"),
                KeyHint(Theme.Keys.toggleTree, "tree"),
                KeyHint(Theme.Keys.copy, "copy path:line"),
                KeyHint(Theme.Keys.optionEnter, "terminal"),
            ]
        case .tool(.sessions):
            return [
                KeyHint(Theme.Keys.enter, "changes"),
                KeyHint(Theme.Keys.optionEnter, "terminal"),
                KeyHint(Theme.Keys.tab, "next tool"),
            ]
        case .tool(.git):
            if state.gitPanel.pickerOpen {
                if state.gitPanel.repoMenuOpen {
                    return [KeyHint(Theme.Keys.up + Theme.Keys.down, "repository"), KeyHint(Theme.Keys.enter, "choose")]
                }
                var hints = [KeyHint(Theme.Keys.up + Theme.Keys.down, "branch"), KeyHint(Theme.Keys.enter, "show this branch")]
                if state.gitPanel.repos.count > 1 { hints.append(KeyHint(Theme.Keys.repository, "repository")) }
                if state.gitPickerShowsFilter && !state.gitPanel.filterFocused { hints.append(KeyHint(Theme.Keys.slash, "filter")) }
                return hints
            }
            if state.gitDraft.composing {
                let submit = state.gitDraft.focus == .description ? Theme.Keys.commandEnter : Theme.Keys.enter
                return [KeyHint(submit, "commit")]
            }
            var hints = [KeyHint(Theme.Keys.up + Theme.Keys.down, "file")]
            if state.focusedGit?.checkedOut == true, !state.gitRows.isEmpty {
                hints.append(KeyHint(Theme.Keys.toggle, "include"))
                hints.append(KeyHint(Theme.Keys.commit, "commit"))
            }
            if state.gitCanUndo { hints.append(KeyHint(Theme.Keys.undo, "undo")) }
            hints.append(KeyHint(Theme.Keys.worktree, "branch"))
            hints.append(KeyHint(Theme.Keys.toggleTree, "list"))
            hints.append(KeyHint(Theme.Keys.push, state.gitSyncVerb.lowercased()))
            // Past six the row would crowd the meter; ⇥ is taught by every other tool.
            if hints.count <= Theme.Limits.gitFooterHints { hints.append(KeyHint(Theme.Keys.tab, "next tool")) }
            return hints
        case .question, .tool(.usage), .tool(.settings):
            return [KeyHint(Theme.Keys.tab, "next tool")]
        }
    }

    /// "2 working · 1 waiting · 3 agents" on the Sessions tool.
    private var footerCounts: String {
        let c = state.sessionCounts
        return Format.sessionCounts(working: c.working, waiting: c.waiting, done: c.done, idle: c.idle, agents: state.runningAgentCount)
    }

    /// The 5-hour limit once the status line has reported it (the last known value, as the
    /// Usage tool shows it), else context with "ctx". A 5-hour window that has reset since
    /// the report is stale, so context shows instead.
    @ViewBuilder
    private var footerMeter: some View {
        if let percent = state.usage.fiveHourPercent, !AppState.limitWindowHasReset(state.usage.fiveHourResetsAt) {
            FooterMeter(
                label: "5h",
                percent: min(100, percent),
                tint: Theme.Colors.limitBar,
                help: state.limitsUpdatedAt.map { "Current session (5h) limit, " + Format.limitsAsOf($0) } ?? "Current session (5h) limit"
            )
        } else if let percent = state.contextPercent {
            FooterMeter(label: "ctx", percent: percent, tint: Theme.Colors.contextBar, help: "Context window used")
        }
    }
}

/// "5h ▬▬▬── 61%": a label, a short bar and the percent, in the footer.
@MainActor
struct FooterMeter: View {
    let label: String
    let percent: Double
    let tint: Color
    let help: String

    var body: some View {
        HStack(spacing: Theme.Size.spaceS) {
            Text(label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.inkTertiary)
            UsageBar(fraction: percent / 100, tint: tint)
                .frame(width: Theme.Size.footerBarWidth)
            Text(Format.percent(percent))
                .font(Theme.Fonts.captionMedium)
                .foregroundStyle(Theme.Colors.inkSecondary)
        }
        .fixedSize()
        .help(help)
    }
}

/// What hangs from the strip into the divider: the short bridge under the selected tool
/// (where the well hangs from; it slides along when the tool changes) and the tool name
/// caption under the tool the mouse rests on (or `⇥` just moved to). Requests and questions
/// hang from their action segments instead, so neither shows then.
@MainActor
private struct ToolHangers: View {
    @ObservedObject var state: AppState
    let content: CardContent
    let anchors: [CardTab: Anchor<CGRect>]
    let dividerY: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let centre: (CardTab) -> CGFloat? = { tab in anchors[tab].map { proxy[$0].midX } }
            ZStack(alignment: .topLeading) {
                if toolsShown, let x = centre(state.selectedTab) {
                    RoundedRectangle(cornerRadius: Theme.Radius.bridge, style: .continuous)
                        .fill(Theme.Colors.bridge)
                        .frame(width: Theme.Size.bridgeWidth, height: Theme.Size.bridgeHeight)
                        .offset(x: x - Theme.Size.bridgeWidth / 2, y: dividerY - Theme.Size.bridgeHeight / 2)
                        .animation(Theme.Motion.toolSelect, value: x)
                }
                ToolLabelPill(tab: toolsShown ? state.toolLabel : nil, centre: centre)
                    .offset(y: dividerY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private var toolsShown: Bool {
        switch content {
        case .settings, .tool: return true
        case .request, .question: return false
        }
    }
}
