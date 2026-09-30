// GitHeader.swift
// The Git tool's header row: the target pill, the branch, the status line (where it stands
// against its upstream, and where every result lands), and the sync pill (Publish, Pull,
// Push or Fetch), which stays put through its whole story (`GitSyncPill`).

import SwiftUI

// MARK: - Header

/// "notchcode › seadevil ▾ W   user-friendly-distribution-plan   [Push 3  P]", or a write's
/// result in the status's place. While a sync is asked the pill stays here armed with ⏎ (the
/// question is in the stage); while any write runs it pulses. A branch checked out nowhere:
/// "notchcode › design/toolbar ▾ W   not checked out · 4 commits ahead of main".
@MainActor
struct GitHeader: View {
    @ObservedObject var state: AppState
    let snap: GitSnapshot
    /// The picker is open: the pill has become the picker's repository pill and the rest has
    /// slid out to the right. The row keeps its height.
    let open: Bool
    let pillSpace: Namespace.ID

    var body: some View {
        HStack(spacing: Theme.Size.spaceM) {
            if !open {
                GitTargetPill(parts: state.gitTargetParts) { state.toggleGitPicker() }
                    .matchedGeometryEffect(id: GitTab.pillID, in: pillSpace, anchor: .leading)
                    .transition(.opacity)
                    .layoutPriority(2)
            }
            if !open {
                rest
                    .transition(Theme.Motion.pickerHeaderTransition)
            }
        }
        .padding(.horizontal, Theme.Size.rowHPadding)
        .frame(height: Theme.Size.gitHeaderHeight)
    }

    /// The branch, the status and the sync pill.
    private var rest: some View {
        let phase = state.gitPhase
        return HStack(spacing: Theme.Size.spaceM) {
            if snap.checkedOut {
                Text(snap.branch ?? "detached HEAD")
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.gitBranch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            HStack(spacing: Theme.Size.spaceM) {
                status(phase)
                if snap.checkedOut && !state.gitTargetIsFocused {
                    Text("not the focused session")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.gitTargetNote)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pill(phase)
                // Its ring bursts draw over the neighbours.
                .zIndex(1)
        }
    }

    /// The status line: a result drops the old line and rises in, and after its hold drops
    /// back out for the status (the stage swap's transition, run by the phase's animation).
    private func status(_ phase: GitPhase) -> some View {
        let text: String
        let font: Font
        let color: Color
        switch phase {
        case .idle, .confirming, .running:
            // The confirm asks in the stage; the status stays what it was.
            (text, font, color) = (state.gitStatusText, Theme.Fonts.caption, Theme.Colors.gitStatus)
        case .done(_, let message):
            (text, font, color) = (message, Theme.Fonts.captionMedium, Theme.Colors.gitPushed)
        case .failed(let op, let message):
            if op == .commit && state.gitDraft.composing {
                // The form says why, next to its Commit pill.
                (text, font, color) = (state.gitStatusText, Theme.Fonts.caption, Theme.Colors.gitStatus)
            } else {
                (text, font, color) = (message, Theme.Fonts.caption, Theme.Colors.gitError)
            }
        }
        return ZStack(alignment: .leading) {
            if !text.isEmpty {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
                    .id(text)
                    .transition(Theme.Motion.paneSwapTransition)
            }
        }
    }

    /// The sync pill: "Push 3  P", "Pull 2  P", "Publish 4  P" in white, "Fetch  P" dark;
    /// while a publish, push or pull is asked it stays here armed with ⏎ (one place to press:
    /// it or ⏎ runs the sync); "✦ Pushing" while any write runs; a check and "Pushed" while a
    /// sync's result holds, so it cannot ask again for the commits just sent. One view whose
    /// parts move (`GitSyncPill`); its count pops when it changes; a failed sync shakes it.
    private func pill(_ phase: GitPhase) -> some View {
        let op = state.gitSyncOp
        let enabled = state.gitCanSync
        let role: ActionRole = enabled && op != .fetch ? .allow : .neutral
        return GitSyncPill(
            phase: phase,
            verb: state.gitSyncVerb,
            // The op's own titles size the pill, so the frame holds through the story.
            sizingOp: phase.op ?? op ?? .push,
            role: role,
            enabled: enabled,
            count: state.gitSyncCount,
            help: phase.isConfirming ? state.gitConfirmText : (enabled ? help(op) : state.gitStatusText)
        ) { state.pressGitPill() }
        .countPop(state.gitSyncCount)
        .shake(trigger: syncFailure(phase))
    }

    /// A failed publish, push, pull or fetch's message: the pill shakes when one arrives.
    private func syncFailure(_ phase: GitPhase) -> String? {
        guard case .failed(let op, let message) = phase, op != .commit, op != .undo else { return nil }
        return message
    }

    private func help(_ op: GitOp?) -> String {
        let remote = snap.remote ?? ""
        switch op {
        case .fetch?: return "Fetch from " + remote
        case .pull?: return "Pull from " + (snap.upstream ?? remote) + " (asks first)"
        default: return (op ?? .push).verb + " this branch (asks first)"
        }
    }
}

/// "notchcode › seadevil ▾  W": the repository dim, then the worktree folder in ink (or the
/// branch in mono when it is checked out nowhere); a press opens the picker.
@MainActor
private struct GitTargetPill: View {
    let parts: (repo: String?, place: String, placeIsBranch: Bool)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Size.actionKeyGap) {
                HStack(spacing: Theme.Size.spaceS) {
                    if let repo = parts.repo {
                        Text(repo)
                            .font(Theme.Fonts.captionMedium)
                            .foregroundStyle(Theme.Colors.gitTargetRepo)
                            .lineLimit(1)
                        Text(Theme.Glyphs.pathChevron)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.gitTargetRepo)
                    }
                    Text(parts.place)
                        .font(parts.placeIsBranch ? Theme.Fonts.monoCaption : Theme.Fonts.action)
                        .foregroundStyle(Theme.Colors.gitTargetPlace)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(Theme.Glyphs.pickerChevron)
                        .font(Theme.Fonts.tiny)
                        .foregroundStyle(Theme.Colors.gitTargetRepo)
                }
                InlineKeycap(Theme.Keys.worktree)
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
            .frame(maxWidth: Theme.Size.gitTargetMaxWidth)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .layoutPriority(2)
        .help("Choose the branch (\(Theme.Keys.worktree))")
    }
}

/// The pill while git writes: Claude's pulsing spark and "Pushing", "Pulling", "Committing",
/// not pressable. The commit form's Commit pill turns into it too.
@MainActor
struct GitRunningPill: View {
    let title: String

    var body: some View {
        Button {} label: {
            HStack(spacing: Theme.Size.actionKeyGap) {
                SparkleGlyph(size: Theme.Size.gitPushingGlyph)
                Text(title)
                    .font(Theme.Fonts.action)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
        }
        .buttonStyle(SegmentStyle(fill: Theme.Colors.neutralActionFill))
        .disabled(true)
    }
}

/// The header's sync pill, one view through its whole story, its frame the widest of its
/// looks so the header never reflows (scale effects only):
/// - arm (P): it pops, its keycap flips P → ⏎ and a ring bursts off it;
/// - waiting: it breathes, from the end of the pop;
/// - run (⏎): it presses in and springs back, the white drains to the quiet fill, "Push 3"
///   slides out left and the pulsing spark and "Pushing" slide in from the right;
/// - done: the check draws itself, a green ring bursts, "Pushed" crossfades in; after the
///   hold, a plain crossfade back;
/// - failed: the white snaps back and P flips in (the header shakes it);
/// - cancel (esc): the keycap flips back, the breath stops, the ring runs in reverse.
/// Reduce Motion: a 0.2 s crossfade for all of it.
@MainActor
private struct GitSyncPill: View {
    let phase: GitPhase
    let verb: String
    let sizingOp: GitOp
    let role: ActionRole
    let enabled: Bool
    let count: Int?
    let help: String
    let action: () -> Void

    /// The pop on arm and the compress on run.
    @State private var punch: CGFloat = 1
    /// The breath's start while waiting; nil when it rests.
    @State private var breathFrom: Date?
    /// The breath's scale as it eases back to 1.
    @State private var breathRest: CGFloat = 1
    @State private var armShots = 0
    @State private var cancelShots = 0
    @State private var doneShots = 0

    private enum Look: Equatable { case ready, armed, running(GitOp), done(GitOp) }

    private var look: Look {
        switch phase {
        case .confirming: return .armed
        case .running(let o): return .running(o)
        case .done(let o, _) where o != .commit && o != .undo: return .done(o)
        case .idle, .done, .failed: return .ready
        }
    }

    private var fill: Color {
        switch look {
        case .armed: return Theme.Colors.action(.allow).fill
        case .ready: return Theme.Colors.action(role).fill
        case .running, .done: return Theme.Colors.neutralActionFill
        }
    }

    var body: some View {
        let look = look
        let reduce = Theme.Motion.reduceMotion
        Button(action: action) {
            ZStack {
                // The widest look sets the frame; the visible parts sit centred in it.
                ZStack {
                    readyParts
                    sizing(sizingOp.runningTitle)
                    sizing(sizingOp.doneTitle)
                }
                .hidden()
                parts(look)
            }
            .padding(.horizontal, Theme.Size.actionHPadding)
            .frame(height: Theme.Size.actionHeight)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                    .fill(fill)
                    // Failed: the white snaps back.
                    .animation(phase.isFailed ? nil : Theme.Motion.gitFillDrain, value: fill)
            }
        }
        .buttonStyle(SegmentStyle(fill: .clear))
        .disabled(look == .ready ? !enabled : look != .armed)
        .opacity(look == .ready && !enabled ? Theme.Opacity.disabled : 1)
        .animation(Theme.Motion.gitFillDrain, value: enabled)
        .help(help)
        .scaleEffect(punch)
        .modifier(Breath(from: breathFrom, rest: breathRest))
        .ringBurst(trigger: armShots == 0 ? nil : armShots, color: Theme.Colors.gitArmRing)
        .ringBurst(trigger: cancelShots == 0 ? nil : cancelShots, color: Theme.Colors.gitArmRing, reverse: true)
        .ringBurst(trigger: doneShots == 0 ? nil : doneShots, color: Theme.Colors.gitDoneRing)
        .onChange(of: look) { old, new in
            // Any move off the confirm stops the breath, easing it back to 1.
            if old == .armed, let from = breathFrom {
                breathRest = Breath.scale(since: from, at: Date())
                breathFrom = nil
                withAnimation(Theme.Motion.gitBreathSettle) { breathRest = 1 }
            }
            guard !reduce else { return }
            switch (old, new) {
            case (_, .armed): arm()
            case (.armed, .ready): cancelShots += 1
            case (.armed, .running): compress()
            case (_, .done): doneShots += 1
            default: break
            }
        }
    }

    /// The label, the count and the keycap; the spark or the check and the title.
    @ViewBuilder
    private func parts(_ look: Look) -> some View {
        HStack(spacing: Theme.Size.actionKeyGap) {
            // The spark while git writes, the check while the result holds.
            ZStack {
                if case .running = look {
                    SparkleGlyph(size: Theme.Size.gitPushingGlyph)
                        .transition(Theme.Motion.gitPillFade)
                }
                if case .done = look {
                    DoneCheckGlyph(size: Theme.Size.gitPushingGlyph)
                        .transition(Theme.Motion.gitPillFade)
                }
            }
            ZStack {
                switch look {
                case .ready, .armed:
                    label
                        .id("ready")
                        .transition(.asymmetric(insertion: Theme.Motion.gitPillFade, removal: Theme.Motion.gitLabelOut))
                case .running(let o):
                    title(o.runningTitle)
                        .id(o.runningTitle)
                        .transition(.asymmetric(insertion: Theme.Motion.gitLabelIn, removal: Theme.Motion.gitPillFade))
                case .done(let o):
                    title(o.doneTitle)
                        .id(o.doneTitle)
                        .transition(Theme.Motion.gitPillFade)
                }
            }
            if look == .ready || look == .armed {
                KeycapFlip(look == .armed ? Theme.Keys.enter : Theme.Keys.push, onLight: look == .armed || role == .allow)
                    .transition(.asymmetric(insertion: KeycapFlip.flip, removal: Theme.Motion.gitPillFade))
            }
        }
    }

    /// "Push 3": dark on the white pill.
    private var label: some View {
        let allow = look == .armed || role == .allow
        let colors = Theme.Colors.action(allow ? .allow : role)
        return HStack(spacing: Theme.Size.spaceS) {
            Text(phase.isConfirming ? (phase.op?.verb ?? verb) : verb)
                .font(Theme.Fonts.action)
                .foregroundStyle(colors.text)
                .lineLimit(1)
                .fixedSize()
            if let count {
                Text("\(count)")
                    .font(Theme.Fonts.captionMedium)
                    .foregroundStyle(allow ? Theme.Colors.keycapTextOnLight : Theme.Colors.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.action)
            .foregroundStyle(Theme.Colors.inkSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// A look's size only (hidden): "Push 3  P".
    private var readyParts: some View {
        HStack(spacing: Theme.Size.actionKeyGap) {
            label
            Keycap(Theme.Keys.push)
        }
    }

    /// A look's size only (hidden): "✦ Pushing".
    private func sizing(_ text: String) -> some View {
        HStack(spacing: Theme.Size.actionKeyGap) {
            Color.clear.frame(width: Theme.Size.gitPushingGlyph, height: Theme.Size.gitPushingGlyph)
            title(text)
        }
    }

    /// P: `PopIn`'s pop in place (0.92 → overshoot → 1), a ring, and the breath from the end
    /// of the pop.
    private func arm() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { punch = Theme.Motion.actionPopStart }
        withAnimation(Theme.Motion.countPopRise) { punch = Theme.Motion.actionPopOvershoot }
        let rise = Theme.Motion.actionPopDuration * Theme.Motion.actionPopRiseShare
        DispatchQueue.main.asyncAfter(deadline: .now() + rise) {
            withAnimation(Theme.Motion.actionPopSettle) { punch = 1 }
        }
        armShots += 1
        breathRest = 1
        breathFrom = Date().addingTimeInterval(Theme.Motion.actionPopDuration)
    }

    /// ⏎: pressed in, sprung back.
    private func compress() {
        withAnimation(Theme.Motion.gitRunCompress) { punch = Theme.Motion.gitRunCompressScale }
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.gitRunCompressDuration) {
            withAnimation(Theme.Motion.pickerPill) { punch = 1 }
        }
    }
}

/// The sync pill waiting on its confirm: 1 ↔ `gitBreathScale`, a sine of `gitBreathPeriod`
/// each way, from `from`; `rest` (easing back to 1) otherwise. Reduce Motion: never starts.
private struct Breath: ViewModifier {
    let from: Date?
    let rest: CGFloat

    static func scale(since from: Date, at now: Date) -> CGFloat {
        let t = max(0, now.timeIntervalSince(from))
        let wave = (1 - cos(.pi * t / Theme.Motion.gitBreathPeriod)) / 2
        return 1 + (Theme.Motion.gitBreathScale - 1) * CGFloat(wave)
    }

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: from == nil)) { context in
            content.scaleEffect(from.map { Self.scale(since: $0, at: context.date) } ?? rest)
        }
    }
}

private extension GitPhase {
    var isConfirming: Bool { if case .confirming = self { return true } else { return false } }
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}
