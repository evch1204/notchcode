// AppState.Card.cs
// Port of Sources/notchcode/State/AppState+Card.swift.
// Opening and closing the card, the tools under the strip, and the keys the card handles.
// Also the two timing helpers every partial uses in place of Swift's `Task.sleep` on the
// main actor: `RunAfter` and `RunOnMain`.

using System.Windows;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    // MARK: - Main-thread timing (Swift: `Task { @MainActor in try? await Task.sleep(...) }`)

    /// Runs `action` on the UI thread after `seconds`, unless the returned source is cancelled
    /// first. Without a WPF application (tests) it runs on the caller's synchronization context,
    /// else on a pool thread under `TimerGate`.
    internal CancellationTokenSource RunAfter(double seconds, Action action)
    {
        var cts = new CancellationTokenSource();
        var token = cts.Token;
        var context = SynchronizationContext.Current;
        _ = Task.Delay(TimeSpan.FromSeconds(Math.Max(0, seconds)), token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            Post(() => { if (!token.IsCancellationRequested) action(); }, context);
        }, TaskScheduler.Default);
        return cts;
    }

    /// Runs `action` on the UI thread (a background read finished).
    internal void RunOnMain(Action action) => Post(action, null);

    /// Serialises timer callbacks when there is no UI thread (tests).
    internal readonly object TimerGate = new();

    private void Post(Action action, SynchronizationContext? context)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is not null) { dispatcher.BeginInvoke(action); return; }
        if (context is not null) { context.Post(_ => action(), null); return; }
        lock (TimerGate) action();
    }

    // MARK: - Hover and the tool label

    public void SetHovering(bool value)
    {
        if (Hovering != value) Hovering = value;
        // The collapsed tools go away with the hover, and their exit may never report.
        if (!value && !IsCardOpen) ClearToolLabel();
    }

    /// The mouse entered or left a tool. The first name waits `ToolLabelDelay`; once one
    /// shows, moving to the next tool moves it at once. Leaving waits `ToolLabelLinger`, so
    /// sliding across the gap between two tools does not blink it.
    public void HoverTool(CardTab tab, bool inside)
    {
        if (inside)
        {
            ToolLabelTask?.Cancel();
            if (ToolLabel is not null) SetToolLabel(tab);
            else ScheduleToolLabel(tab, Theme.Motion.ToolLabelDelay);
        }
        else if (ToolLabel == tab || ToolLabel is null)
        {
            ToolLabelTask?.Cancel();
            ScheduleToolLabel(null, Theme.Motion.ToolLabelLinger);
        }
    }

    /// `⇥` or `1–5` moved the selection: its name shows under it for a moment.
    private void FlashToolLabel()
    {
        ToolLabelTask?.Cancel();
        SetToolLabel(SelectedTab);
        ScheduleToolLabel(null, Theme.Motion.ToolLabelKeyboardHold);
    }

    private void ClearToolLabel()
    {
        ToolLabelTask?.Cancel();
        SetToolLabel(null);
    }

    private void SetToolLabel(CardTab? tab)
    {
        if (ToolLabel != tab) ToolLabel = tab;
    }

    private void ScheduleToolLabel(CardTab? tab, double seconds)
        => ToolLabelTask = RunAfter(seconds, () => SetToolLabel(tab));

    // MARK: - Opening and closing

    public void OpenCard(CardTab? tab = null)
    {
        if (CurrentPending is { } req)
        {
            CardOpenedForRequest = true;
            FocusedSessionId = req.SessionId;
        }
        else if (tab is CardTab t)
        {
            QuestionShown = false;
            SelectedTab = t;
        }
        if (FocusedSessionId is null || Session(FocusedSessionId) is null)
            FocusedSessionId = PrimarySession?.Id;
        if (FocusedSessionId is { } id)
        {
            var index = OrderedSessions.FindIndex(s => s.Id == id);
            if (index >= 0) SessionCursor = index;
        }
        if (SelectedTab == CardTab.Files) LoadRepoTree();
        if (SelectedTab == CardTab.Usage) UsagePaneShown();
        IsCardOpen = true;
        GitCardOpened();
        SkipFocusReturn = false;
        ClearToolLabel();
        RecomputeUsage();
        Refresh();
    }

    public void CloseCard()
    {
        if (!IsCardOpen) return;
        IsCardOpen = false;
        CardOpenedForRequest = false;
        QuestionShown = false;
        ClearToolLabel();
        if (!SelectedTab.IsBrowsable) SelectedTab = CardTab.Sessions;
        FilesTool = FilesTool with { FilterFocused = false };
        RequestDiff = null;
        GitCardClosed();
        Refresh();
    }

    /// Settings is a page inside the card. A pending request still takes the card first.
    public void OpenSettings()
    {
        if (CurrentPending is not null) return;
        if (SelectedTab != CardTab.Settings)
            TabBeforeSettings = SelectedTab.IsBrowsable ? SelectedTab : CardTab.Sessions;
        if (IsCardOpen) SelectTab(CardTab.Settings);
        else OpenCard(CardTab.Settings);
    }

    public void CloseSettings()
    {
        if (SelectedTab != CardTab.Settings) return;
        SelectTab(TabBeforeSettings);
    }

    /// Row click or ⏎ in the Sessions tab: show that session's changes.
    public void SelectSession(Session session)
    {
        FocusedSessionId = session.Id;
        var index = OrderedSessions.FindIndex(s => s.Id == session.Id);
        if (index >= 0) SessionCursor = index;
        RowCursor = 0;
        SelectTab(CardTab.Changes);
    }

    /// Read once by the window when the card closes: a teleport took the focus elsewhere.
    public bool TakeSkipFocusReturn()
    {
        var value = SkipFocusReturn;
        SkipFocusReturn = false;
        return value;
    }

    /// Shows a short inline hint for a couple of seconds.
    public void Flash(string text)
    {
        Hint = text;
        HintTask?.Cancel();
        HintTask = RunAfter(Theme.Timing.HintDuration, () => Hint = null);
    }

    public void ToggleFromNotchTap()
    {
        if (IsCardOpen) CloseCard();
        else if (CurrentPending is not null) OpenCard();
        else if (Question is not null) OpenQuestion();
        // From the notch the card always lands on Sessions; only a blocking request (above) differs.
        else OpenCard(CardTab.Sessions);
    }

    /// Opens the card on the question preview (it can only be answered in the terminal).
    public void OpenQuestion()
    {
        if (Question is not { } question) return;
        FocusedSessionId = question.SessionId;
        QuestionShown = true;
        OpenCard();
    }

    public void SelectTab(CardTab tab)
    {
        QuestionShown = false;
        if (tab != SelectedTab)
        {
            RowCursor = 0;
            var order = CardTabs.Browsable;
            int from = IndexOf(order, SelectedTab), to = IndexOf(order, tab);
            TabMovedForward = from >= 0 && to >= 0 ? to > from : true;
        }
        SelectedTab = tab;
        if (tab != CardTab.Files) FilesTool = FilesTool with { FilterFocused = false };
        if (tab == CardTab.Files) LoadRepoTree();
        if (tab == CardTab.Git) GitToolShown();
        if (tab == CardTab.Usage) UsagePaneShown();
        Refresh();
    }

    private static int IndexOf(IReadOnlyList<CardTab> list, CardTab tab)
    {
        for (int i = 0; i < list.Count; i++) if (list[i] == tab) return i;
        return -1;
    }

    /// Ctrl Q while the card is open, or the Quit button in Settings. Pending requests are left
    /// unanswered on purpose: their hooks time out and the terminal prompt takes over.
    public void Quit() => Application.Current?.Shutdown();

    // MARK: - Keys

    /// Returns true when the key was used.
    public bool HandleKey(NotchKey key)
    {
        if (Mode != NotchMode.Card && Mode != NotchMode.Attention) return false;
        if (key == NotchKey.Quit) { Quit(); return true; }

        bool filesOpen = IsCardOpen && IsShowingTool(CardTab.Files);
        if (key == NotchKey.Escape && filesOpen && (FilesTool.FilterFocused || FilesTool.Filter.Length > 0))
        {
            // Esc clears the filter first; a second esc closes the card.
            FilesTool = FilesTool with { Filter = "", FilterFocused = false };
            return true;
        }
        if (filesOpen && FilesTool.FilterFocused)
        {
            // Typing goes to the filter field; only the tree keys and teleport stay with the card.
            if (key != NotchKey.Up && key != NotchKey.Down && key != NotchKey.Primary && key != NotchKey.Teleport) return false;
        }

        bool gitShown = IsCardOpen && IsShowingTool(CardTab.Git);
        if (gitShown && GitPanel.PickerOpen && GitPanel.FilterFocused && !GitPanel.RepoMenuOpen)
        {
            // Typing goes to the branch filter; only the picker's keys stay with the card.
            if (key != NotchKey.Up && key != NotchKey.Down && key != NotchKey.Primary && key != NotchKey.Escape) return false;
        }
        if (gitShown && !GitPanel.PickerOpen && GitDraft.Composing && GitDraft.Focus is not null)
        {
            // A commit field has the keys: typing, arrows, ⇥, space and ⏎ (the summary's
            // submit commits, the co-author field's adds) go to it; only esc and Ctrl ⏎ stay
            // with the card, and ⌫ in the empty co-author field, which takes the last chip.
            if (key == NotchKey.Deny && GitDraft.Focus == Features.Git.GitDraftFocus.Coauthor
                && GitDraft.CoauthorText.Length == 0 && GitDraft.Coauthors.Count > 0)
            {
                RemoveLastGitCoauthor();
                return true;
            }
            if (key != NotchKey.Escape && key != NotchKey.Submit) return false;
        }
        // Esc in the Git tool closes the repository dropdown, then clears the branch filter,
        // then leaves the picker, then the commit form, then cancels the confirm, before it
        // closes the card.
        if (key == NotchKey.Escape && gitShown && GitEscape()) return true;
        // Esc in Changes brings a hidden timeline back, then closes the diff pane, before it
        // closes the card.
        if (key == NotchKey.Escape && IsCardOpen && IsShowingTool(CardTab.Changes) && ChangesEscape()) return true;
        if (key == NotchKey.Escape)
        {
            if (!IsCardOpen) return false;
            if (CurrentPending is { } open && RequestDiffPath(open) is not null)
            {
                // Esc closes the diff first, then the card.
                CloseRequestDiff();
            }
            else if (CardContent is CardContent.Settings)
            {
                CloseSettings();
            }
            else
            {
                CloseCard();
            }
            return true;
        }
        if (key == NotchKey.Settings)
        {
            if (IsCardOpen && SelectedTab == CardTab.Settings) CloseSettings();
            else OpenSettings();
            return true;
        }
        if (key == NotchKey.Teleport)
        {
            var ordered = OrderedSessions;
            if (IsCardOpen && IsShowingTool(CardTab.Sessions) && SessionCursor >= 0 && SessionCursor < ordered.Count)
                Teleport(ordered[SessionCursor]);
            else
                Teleport(FocusedSession);
            return true;
        }

        if (CurrentPending is { } req)
        {
            // `Answer` swallows a press that comes before `AnswerKeysAllowedAt`.
            switch (key.Kind)
            {
                case NotchKeyKind.Primary:
                    Answer(RequestAnswer.Allow, req);
                    break;
                case NotchKeyKind.Deny:
                    Answer(RequestAnswer.Deny, req);
                    break;
                case NotchKeyKind.Always:
                    if (req.Kind == PendingRequestKind.Commit) return false;
                    Answer(RequestAnswer.Always, req);
                    break;
                case NotchKeyKind.Edit:
                    if (req.Kind != PendingRequestKind.Commit) return false;
                    Answer(RequestAnswer.Edit, req);
                    break;
                case NotchKeyKind.Diff:
                    return ToggleRequestDiffAtCursor(req);
                case NotchKeyKind.Up:
                case NotchKeyKind.Down:
                {
                    if (!IsCardOpen) return false;
                    int step = key == NotchKey.Up ? -1 : 1;
                    if (req.Kind == PendingRequestKind.Plan || RequestDiffPath(req) is not null)
                    {
                        // One scroll command: a diff reads it as lines, the plan card as blocks.
                        int unit = req.Kind == PendingRequestKind.Plan ? Theme.Limits.PlanScrollBlocks : Theme.Limits.RequestDiffScrollLines;
                        RequestDiffScroll = new RequestDiffScroll { Seq = RequestDiffScroll.Seq + 1, Delta = step * unit };
                    }
                    else if (req.Kind == PendingRequestKind.Commit && req.Files.Count > 0)
                    {
                        int shown = Math.Min(req.Files.Count, Theme.Limits.CommitMaxFileRows);
                        RequestRowCursor = Math.Max(0, Math.Min(shown - 1, RequestRowCursor + step));
                    }
                    else
                    {
                        return false;
                    }
                    break;
                }
                default:
                    return false;
            }
            return true;
        }

        if (!IsCardOpen) return false;

        if (ShowingQuestion)
        {
            switch (key.Kind)
            {
                case NotchKeyKind.Primary:
                    Teleport(Question is { } q ? Session(q.SessionId) : null);
                    return true;
                case NotchKeyKind.Number:
                    return true; // options are read-only; swallow so nothing else reacts
                case NotchKeyKind.NextTab:
                    CycleTab(1);
                    return true;
                case NotchKeyKind.PreviousTab:
                    CycleTab(-1);
                    return true;
                default:
                    return false; // the tool's keys wait until a tool shows
            }
        }

        if (SelectedTab == CardTab.Files && HandleFilesKey(key) is bool filesUsed) return filesUsed;
        if (SelectedTab == CardTab.Git && HandleGitKey(key) is bool gitUsed) return gitUsed;
        if (SelectedTab == CardTab.Changes && HandleChangesKey(key) is bool changesUsed) return changesUsed;
        // R in Usage: run `claude -p /usage` now.
        if (SelectedTab == CardTab.Usage && key == NotchKey.Repository)
        {
            RefreshPlanUsage(force: true);
            return true;
        }

        switch (key.Kind)
        {
            case NotchKeyKind.Number:
            {
                int n = key.N;
                if (n < 1 || n > CardTabs.Browsable.Count) return false;
                SelectTab(CardTabs.Browsable[n - 1]);
                FlashToolLabel();
                break;
            }
            case NotchKeyKind.NextTab:
                CycleTab(1);
                break;
            case NotchKeyKind.PreviousTab:
                CycleTab(-1);
                break;
            case NotchKeyKind.Up:
                if (SelectedTab == CardTab.Sessions && !Sessions.IsEmpty) SessionCursor = Math.Max(0, SessionCursor - 1);
                else return false;
                break;
            case NotchKeyKind.Down:
                if (SelectedTab == CardTab.Sessions && !Sessions.IsEmpty) SessionCursor = Math.Min(Sessions.Count - 1, SessionCursor + 1);
                else return false;
                break;
            case NotchKeyKind.Primary:
            {
                if (SelectedTab != CardTab.Sessions) return false;
                var ordered = OrderedSessions;
                if (SessionCursor < 0 || SessionCursor >= ordered.Count) return false;
                SelectSession(ordered[SessionCursor]);
                break;
            }
            default:
                return false;
        }
        return true;
    }

    private void CycleTab(int step)
    {
        var tabs = CardTabs.Browsable;
        // From Settings or the question, ⇥ lands on the first tool and ⇧⇥ on the last.
        bool onTool = CardContent is CardContent.Tool;
        int found = onTool ? IndexOf(tabs, SelectedTab) : -1;
        int current = found >= 0 ? found : (step > 0 ? -1 : tabs.Count);
        int next = ((current + step) % tabs.Count + tabs.Count) % tabs.Count;
        SelectTab(tabs[next]);
        FlashToolLabel();
    }
}
