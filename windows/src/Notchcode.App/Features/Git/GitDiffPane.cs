// GitDiffPane.cs
// Port of Sources/notchcode/Features/Git/GitDiffPane.swift.
// The Git tool's stage, the right of the well: a header that stays on top (the Ctrl B pill,
// then the file, "Commit to main", or nothing for a confirm) over one of four things in one
// rectangle: the selected file's reviewer diff, the clean note, the commit form (the dock's
// summary box arrives from the rail and the description, co-authors and bottom row rise under
// it), or the confirm of a publish, push or pull (the question, "⏎ or Push again" and Cancel;
// the sync pill stays in the header). They trade places with a drop and a rise, never a slide.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Git;

// MARK: - The stage

/// The stage. While a publish, push or pull is asked or running, the confirm takes the
/// diff's (or the clean note's) place; while the owner writes a commit, the form does.
public sealed class GitDiffPane : ColumnStack
{
    private readonly Grid header = new() { Height = Theme.Size.GitStageHeaderHeight };
    private readonly RowStack headerRow = new() { Spacing = Theme.Size.SpaceM };
    private readonly Grid headerLook = new();
    private readonly Grid body = new();
    private readonly Grid contentRegion = new();
    private readonly Grid contentHost = new();
    public GitCommitForm Form { get; } = new();
    private readonly GitConfirm confirm = new();
    private UIElement? togglePill;
    private string? toggleKey;
    private string? lookKey;
    private FrameworkElement? lookElement;
    private string? contentKey;
    private FrameworkElement? contentElement;
    private bool? regionShown;

    public GitDiffPane()
    {
        Spacing = Theme.Size.SpaceS;
        headerRow.Margin = new Thickness(Theme.Size.PreviewHPadding, 0, Theme.Size.PreviewHPadding, 0);
        headerRow.Children.Add(Kit.Flex(headerLook));
        header.Children.Add(headerRow);
        Children.Add(header);
        contentRegion.Children.Add(contentHost);
        // The content, the form and the confirm all stay in the tree; only their parts come and
        // go, so each part's transition fires.
        body.Children.Add(contentRegion);
        body.Children.Add(Form);
        body.Children.Add(confirm);
        Children.Add(Kit.Flex(body));
    }

    public void Update(AppState state, GitSnapshot snap)
    {
        var file = state.GitSelectedFile;
        var phase = state.GitPhase;
        bool asking = GitConfirm.Shows(phase);
        bool composing = !asking && state.GitDraft.Composing;

        // The Ctrl B pill.
        var key = state.GitListCollapsed + "|" + (file is not null);
        if (key != toggleKey)
        {
            toggleKey = key;
            if (togglePill is not null) headerRow.Children.Remove(togglePill);
            togglePill = new TreeTogglePill(state.GitListCollapsed, file is not null, state.ToggleGitList, "rail");
            headerRow.Children.Insert(0, togglePill);
        }
        Header(asking || composing ? null : file, composing, snap);

        // The diff or the clean note, dropping away while the form or the confirm has the stage.
        bool region = !asking && !composing;
        if (regionShown != region)
        {
            bool animate = regionShown is not null;
            regionShown = region;
            if (region)
            {
                contentRegion.Visibility = Visibility.Visible;
                if (animate) Transitions.Insert(contentRegion, Theme.Motion.PaneSwapTransition);
            }
            else if (animate)
            {
                Transitions.Remove(contentRegion, Theme.Motion.PaneSwapTransition, () => { if (regionShown == false) contentRegion.Visibility = Visibility.Hidden; });
            }
            else
            {
                contentRegion.Visibility = Visibility.Hidden;
            }
        }
        Content(file, snap);
        Form.Update(state, composing);
        confirm.Update(state, phase);
    }

    /// The Ctrl B pill, then the file (name, M/A/D, counts), or "Commit to main", or nothing.
    /// Each look in its own element, so the old one drops out before the new one rises in.
    private void Header(FileChange? file, bool composing, GitSnapshot snap)
    {
        var key = composing ? "commit|" + snap.Branch : file is not null ? "file|" + file.Path + "|" + file.Added + "|" + file.Removed + "|" + file.Kind : "";
        if (key == lookKey) return;
        bool animate = lookKey is not null;
        lookKey = key;
        if (lookElement is { } old)
        {
            if (animate) Transitions.Remove(old, Theme.Motion.PaneSwapTransition, () => headerLook.Children.Remove(old));
            else headerLook.Children.Remove(old);
        }
        lookElement = null;
        FrameworkElement? next = null;
        if (composing)
        {
            var branch = new TrimText(snap.Branch ?? "HEAD", Theme.Fonts.MonoCaption, Theme.Brushes.GitBranch, TrimMode.Middle);
            next = new RowStack(Theme.Size.SpaceS, Kit.Text("Commit to", Theme.Fonts.Caption, Theme.Brushes.InkSecondary, TextTrimming.None), branch);
        }
        else if (file is not null)
        {
            var name = new PathLabel(file.Path);
            RowStack.SetPriority(name, 1);
            next = new RowStack(Theme.Size.SpaceM, name, new FileKindBadge(file.Kind), new DiffCounts(file.Added, file.Removed));
        }
        if (next is null) return;
        next.HorizontalAlignment = HorizontalAlignment.Left;
        next.VerticalAlignment = VerticalAlignment.Center;
        headerLook.Children.Add(next);
        lookElement = next;
        if (animate) Transitions.Insert(next, Theme.Motion.PaneSwapTransition);
    }

    private void Content(FileChange? file, GitSnapshot snap)
    {
        int? fileLines = file is not null && snap.LineCounts.TryGetValue(file.Path, out var n) ? n : null;
        var key = file is null ? "clean|" + GitTab.EmptyText(snap)
            : file.Path + "|" + file.Added + "|" + file.Removed + "|" + file.Patch.Count + "|" + fileLines;
        if (key == contentKey) return;
        bool animate = contentKey is not null;
        contentKey = key;
        if (contentElement is { } old)
        {
            if (animate) Transitions.Remove(old, TransitionSpec.Opacity(Theme.Motion.PreviewFade, Theme.Motion.PreviewFade), () => contentHost.Children.Remove(old));
            else contentHost.Children.Remove(old);
        }
        FrameworkElement next;
        if (file is not null)
        {
            var lines = file.DiffLines();
            next = lines.Count == 0
                ? new EmptyNote(file.Kind == "new" ? "Empty file" : "No text diff")
                : new ReviewerDiff(file, lines, fileLines);
        }
        else
        {
            next = new GitCleanNote(GitTab.EmptyText(snap));
        }
        contentHost.Children.Add(next);
        contentElement = next;
        if (animate) Transitions.Insert(next, TransitionSpec.Opacity(Theme.Motion.PreviewFade, Theme.Motion.PreviewFade));
    }
}

/// The stage with nothing to show: a green check, then "Nothing to commit · up to date".
public sealed class GitCleanNote : Grid
{
    public GitCleanNote(string text)
    {
        var row = new RowStack(Theme.Size.SpaceM, new DoneCheckGlyph(Theme.Size.GitCleanCircle),
            Kit.Text(text, Theme.Fonts.Body, Theme.Brushes.InkSecondary))
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Children.Add(row);
    }
}

// MARK: - The confirm

/// Places its one child with its centre at `Fraction` of its height, centred across.
public class FractionCentre : Panel
{
    public double Fraction { get; set; } = Theme.Size.GitConfirmCentre;

    protected override Size MeasureOverride(Size available)
    {
        foreach (UIElement child in InternalChildren) child.Measure(new Size(available.Width, double.PositiveInfinity));
        return new Size(double.IsInfinity(available.Width) ? 0 : available.Width, double.IsInfinity(available.Height) ? 0 : available.Height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        foreach (UIElement child in InternalChildren)
        {
            var size = child.DesiredSize;
            child.Arrange(new Rect((final.Width - size.Width) / 2, final.Height * Fraction - size.Height / 2, size.Width, size.Height));
        }
        return final;
    }
}

/// The confirm in the stage, its centre at 40 % of the height: "Push 3 commits to
/// origin/seadevil?", "Publish seadevil to origin?" or "Pull 2 commits from origin/main?",
/// then "⏎ or Push again", then Cancel (esc). The pill itself stays in the header, armed with
/// ⏎. Stays in the tree with nothing in it outside the confirm, so its parts transition.
/// While git runs the question becomes "Pushing to origin/seadevil…" and the hint and Cancel
/// drop out. A fetch, a commit and an undo never show it.
public sealed class GitConfirm : FractionCentre
{
    private readonly ColumnStack stack = new() { Spacing = Theme.Size.SpaceM };
    private TextBlock? question;
    private FrameworkElement? hint;
    private FrameworkElement? cancel;
    private bool shownBefore, confirmingBefore;
    private string? hintVerb;

    public GitConfirm()
    {
        Children.Add(stack);
    }

    /// The confirm has the stage: a publish, push or pull is asked or running.
    public static bool Shows(GitPhase phase) => phase switch
    {
        GitPhase.Confirming c => c.Op.Confirms,
        GitPhase.Running r => r.Op.Confirms,
        _ => false,
    };

    public void Update(AppState state, GitPhase phase)
    {
        bool confirming = phase is GitPhase.Confirming;
        bool shown = Shows(phase);
        bool running = shown && !confirming;
        IsHitTestVisible = confirming;

        if (shown && question is null)
        {
            question = Kit.Wrapped("", Theme.Fonts.BodyMedium, Theme.Brushes.Ink, maxLines: 2);
            question.TextAlignment = TextAlignment.Center;
            question.MaxWidth = Theme.Size.GitConfirmMaxWidth;
            question.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Insert(0, question);
            Transitions.Insert(question, Theme.Motion.ConfirmRise(Theme.Motion.ConfirmQuestionDelay));
        }
        else if (!shown && question is { } q)
        {
            question = null;
            Transitions.Remove(q, Theme.Motion.ConfirmRise(Theme.Motion.ConfirmQuestionDelay), () => stack.Children.Remove(q));
        }
        if (question is not null)
        {
            var text = running ? state.GitRunningText : state.GitConfirmText;
            if (question.Text != text)
            {
                bool swap = question.Text.Length > 0;
                question.Text = text;
                if (swap) Transitions.FadeIn(question);
            }
        }

        var verb = phase.OpValue?.Verb;
        if (confirming && (hint is null || hintVerb != verb))
        {
            RemoveHint();
            hintVerb = verb;
            var row = new RowStack(Theme.Size.SpaceS, new Keycap(Theme.Keys.Enter),
                Kit.Text("or " + verb + " again", Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None))
            { HorizontalAlignment = HorizontalAlignment.Center };
            var cancelSegment = new ActionSegment("Cancel", Theme.Keys.Escape, ActionRole.Neutral, () => state.CancelGitConfirm())
            { HorizontalAlignment = HorizontalAlignment.Center };
            hint = row;
            cancel = cancelSegment;
            stack.Children.Add(row);
            stack.Children.Add(cancelSegment);
            Transitions.Insert(row, Theme.Motion.ConfirmRise(Theme.Motion.ConfirmCancelDelay));
            Transitions.Insert(cancelSegment, Theme.Motion.ConfirmRise(Theme.Motion.ConfirmCancelDelay));
        }
        else if (!confirming && hint is not null)
        {
            RemoveHint();
        }
        shownBefore = shown;
        confirmingBefore = confirming;
        _ = shownBefore && confirmingBefore;
    }

    private void RemoveHint()
    {
        foreach (var element in new[] { hint, cancel })
        {
            if (element is null) continue;
            var e = element;
            Transitions.Remove(e, Theme.Motion.ConfirmRise(Theme.Motion.ConfirmCancelDelay), () => stack.Children.Remove(e));
        }
        hint = null;
        cancel = null;
    }
}

// MARK: - The commit form

/// A text field in the form's look: no chrome, ink text and caret, a tertiary prompt while empty.
internal sealed class FormField : Grid
{
    public TextBox Box { get; } = new()
    {
        Background = Brushes.Transparent,
        BorderThickness = new Thickness(0),
        Padding = new Thickness(0),
        Foreground = Theme.Brushes.Ink,
        CaretBrush = Theme.Brushes.Ink,
        SelectionBrush = Theme.Brushes.Selection,
        VerticalContentAlignment = VerticalAlignment.Center,
        FocusVisualStyle = null,
    };
    private readonly TextBlock prompt;

    public FormField(FontSpec font, bool multiline = false)
    {
        font.Apply(Box);
        // The TextBox template pads its text 2 DIP each side; take that off so it lines up.
        Box.Margin = new Thickness(-Theme.Size.TextBoxInset, 0, -Theme.Size.TextBoxInset, 0);
        prompt = Kit.Text("", font, Theme.Brushes.FilterPlaceholder);
        prompt.IsHitTestVisible = false;
        if (multiline)
        {
            Box.AcceptsReturn = true;
            Box.TextWrapping = TextWrapping.Wrap;
            Box.VerticalContentAlignment = VerticalAlignment.Top;
            Box.VerticalScrollBarVisibility = ScrollBarVisibility.Hidden;
            prompt.VerticalAlignment = VerticalAlignment.Top;
        }
        Children.Add(Box);
        Children.Add(prompt);
        Box.TextChanged += (_, _) => prompt.Visibility = Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public string Prompt { set => prompt.Text = value; }

    /// Sets the text without echoing it back as an edit.
    public void SetText(string text)
    {
        if (Box.Text == text) return;
        int caret = Box.CaretIndex;
        Box.Text = text;
        Box.CaretIndex = Math.Min(caret, text.Length);
    }
}

/// The commit form, GitHub Desktop's: the summary (its length past 50, red past 72; the
/// one-file prefill as its prompt), whose box is the dock's field arrived from the rail; the
/// description filling the stage; the co-authors when shown (chips, a field, the "recent"
/// suggestions); git's error when the commit failed; then "Commit 3 ⏎" (the header names the
/// branch, the footer the keys), "@ Co-author" and Cancel (esc). Always in the tree, its parts
/// come and go with `shown`, so each rises in on its own beat. Its fields' focus is the
/// draft's, both ways.
public sealed class GitCommitForm : ColumnStack
{
    private AppState? state;
    private bool updating;
    private bool? shownBefore;
    private bool coauthorsShownBefore;
    private int rejectsBefore;

    /// The summary's box: what the dock's field becomes (GitTab travels it in).
    public Border SummaryBox { get; }
    private readonly FormField summary = new(Theme.Fonts.Body);
    private readonly TextBlock summaryCount;
    private readonly Border descriptionBox;
    private readonly FormField description = new(Theme.Fonts.Body, multiline: true);
    private readonly ColumnStack coauthors = new() { Spacing = Theme.Size.SpaceS };
    private readonly Border coauthorBox;
    private readonly RowStack chips = new() { Spacing = Theme.Size.GitChipGap };
    private readonly FormField coauthorField = new(Theme.Fonts.Caption);
    private readonly RowStack suggestions = new() { Spacing = Theme.Size.GitChipGap, Height = Theme.Size.GitSuggestionRowHeight, ClipToBounds = true };
    private readonly TextBlock failureText;
    private readonly RowStack bottom = new() { Spacing = Theme.Size.SpaceM };
    private readonly Grid commitHost = new();
    private string? commitKey;
    /// "@ Co-author" or "@ 2": rebuilt when its title changes (ActionSegment's title is fixed).
    private readonly Grid coauthorHost = new();
    private string? coauthorTitle;
    private string? chipsKey, suggestionsKey;

    public GitCommitForm()
    {
        Spacing = Theme.Size.SpaceM;
        Margin = new Thickness(Theme.Size.PreviewHPadding, 0, Theme.Size.PreviewHPadding, 0);

        summaryCount = Kit.Text("", Theme.Fonts.Tiny, Theme.Brushes.InkTertiary, TextTrimming.None);
        SummaryBox = FieldBox(new RowStack(Theme.Size.SpaceS, Kit.Flex(summary), summaryCount));
        SummaryBox.Height = Theme.Size.GitFieldHeight;
        SummaryBox.Padding = new Thickness(Theme.Size.GitFieldHPadding, 0, Theme.Size.GitFieldHPadding, 0);

        // The text box insets its text by `gitDescriptionTextInset`; the box's padding takes
        // that off so the text lines up with the summary's.
        description.Prompt = "Description";
        descriptionBox = FieldBox(description);
        descriptionBox.Padding = new Thickness(Theme.Size.GitFieldHPadding, Theme.Size.GitFieldVPadding, Theme.Size.GitFieldHPadding, Theme.Size.GitFieldVPadding);
        descriptionBox.MinHeight = Theme.Size.GitDescriptionMinHeight;
        Kit.Flex(descriptionBox);

        coauthorField.Prompt = "Co-author" + Theme.Glyphs.Separator + "name <email>";
        coauthorBox = FieldBox(new RowStack(Theme.Size.GitChipGap,
            Kit.Text(Theme.Keys.Coauthor, Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None),
            chips,
            Kit.Flex(coauthorField),
            Kit.Text(Theme.Keys.Enter + " adds", Theme.Fonts.Tiny, Theme.Brushes.InkTertiary, TextTrimming.None)));
        coauthorBox.Height = Theme.Size.GitFieldHeight;
        coauthorBox.Padding = new Thickness(Theme.Size.GitFieldHPadding, 0, Theme.Size.GitFieldHPadding, 0);
        coauthors.Children.Add(coauthorBox);
        coauthors.Children.Add(suggestions);

        failureText = Kit.Wrapped("", Theme.Fonts.Caption, Theme.Brushes.GitError, maxLines: 2);

        commitHost.HorizontalAlignment = HorizontalAlignment.Left;
        RowStack.SetPriority(commitHost, 1);
        bottom.Children.Add(commitHost);
        bottom.Children.Add(Kit.Spacer(Theme.Size.SpaceM));
        bottom.Children.Add(coauthorHost);
        bottom.Children.Add(new ActionSegment("Cancel", Theme.Keys.Escape, ActionRole.Neutral, () => state?.CancelGitCommitForm()));

        foreach (var part in new UIElement[] { SummaryBox, descriptionBox, coauthors, failureText, bottom })
        {
            part.Visibility = Visibility.Collapsed;
            Children.Add(part);
        }

        Wire(summary, GitDraftFocus.Summary);
        Wire(description, GitDraftFocus.Description);
        Wire(coauthorField, GitDraftFocus.Coauthor);
        summary.Box.TextChanged += (_, _) => { if (!updating) state?.SetGitSummary(summary.Box.Text); };
        description.Box.TextChanged += (_, _) => { if (!updating) state?.SetGitDescription(description.Box.Text); };
        coauthorField.Box.TextChanged += (_, _) => { if (!updating) state?.SetGitCoauthorText(coauthorField.Box.Text); };
        summary.Box.PreviewKeyDown += (_, e) =>
        {
            // ⏎ in the summary commits (Return itself, not the field losing focus on ⇥).
            if (e.Key == Key.Return && Keyboard.Modifiers == ModifierKeys.None) { state?.RunGitCommit(); e.Handled = true; }
        };
        coauthorField.Box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Return && Keyboard.Modifiers == ModifierKeys.None) { state?.AddGitCoauthor(); e.Handled = true; }
            else if (e.Key == Key.Back && coauthorField.Box.Text.Length == 0) { state?.RemoveLastGitCoauthor(); e.Handled = true; }
        };
    }

    /// While a field has the keys only esc and Ctrl ⏎ stay with the card.
    private void Wire(FormField field, GitDraftFocus focus)
    {
        field.Box.GotKeyboardFocus += (_, _) => { if (!updating && state?.GitDraft.Focus != focus) state?.SetGitDraftFocus(focus); RingFocus(); };
        field.Box.LostKeyboardFocus += (_, _) => RingFocus();
        field.Box.PreviewKeyDown += (_, e) =>
        {
            if (state is null) return;
            if (e.Key == Key.Escape) { state.GitEscape(); e.Handled = true; }
            else if (e.Key == Key.Return && (Keyboard.Modifiers & ModifierKeys.Control) != 0) { state.RunGitCommit(); e.Handled = true; }
        };
    }

    /// A field's box: the quiet fill, and a ring while its field has the keys.
    private static Border FieldBox(UIElement content) => new()
    {
        Child = content,
        Background = Theme.Brushes.FilterFill,
        CornerRadius = new CornerRadius(Theme.Radius.Chip),
        BorderThickness = new Thickness(Theme.Size.GitFieldFocusStroke),
        BorderBrush = Brushes.Transparent,
    };

    private void RingFocus()
    {
        SummaryBox.BorderBrush = summary.Box.IsKeyboardFocused ? Theme.Brushes.GitFieldFocusRing : Brushes.Transparent;
        descriptionBox.BorderBrush = description.Box.IsKeyboardFocused ? Theme.Brushes.GitFieldFocusRing : Brushes.Transparent;
        coauthorBox.BorderBrush = coauthorField.Box.IsKeyboardFocused ? Theme.Brushes.GitFieldFocusRing : Brushes.Transparent;
    }

    public void Update(AppState state, bool shown)
    {
        this.state = state;
        updating = true;
        try { Apply(state, shown); }
        finally { updating = false; }
    }

    private void Apply(AppState state, bool shown)
    {
        var draft = state.GitDraft;
        string? failure = state.GitPhase is GitPhase.Failed { Op: GitOp.Commit } f ? f.Message : null;
        bool committing = state.GitPhase is GitPhase.Running { Op: GitOp.Commit };
        IsHitTestVisible = shown;

        summary.SetText(draft.Summary);
        summary.Prompt = state.GitSummaryPlaceholder;
        int count = draft.Summary.Length;
        summaryCount.Visibility = count > Theme.Limits.GitSummaryIdeal ? Visibility.Visible : Visibility.Collapsed;
        summaryCount.Text = count.ToString();
        summaryCount.Foreground = count > Theme.Limits.GitSummaryMax ? Theme.Brushes.GitError : Theme.Brushes.InkTertiary;
        description.SetText(draft.Description);
        coauthorField.SetText(draft.CoauthorText);
        foreach (var locked in new UIElement[] { SummaryBox, descriptionBox, coauthorBox })
        {
            locked.IsEnabled = !committing;
            locked.Opacity = committing ? Theme.Opacity.GitLocked : 1;
        }

        // Co-author chips and the "recent" suggestions, the first ringed.
        var ck = string.Join("\u001f", draft.Coauthors);
        if (ck != chipsKey)
        {
            chipsKey = ck;
            chips.Children.Clear();
            foreach (var entry in draft.Coauthors)
            {
                var e = entry;
                chips.Children.Add(new GitCoauthorChip(e, onRemove: () => this.state?.RemoveGitCoauthor(e)));
            }
        }
        var list = state.GitCoauthorSuggestions;
        var sk = string.Join("\u001f", list);
        if (sk != suggestionsKey)
        {
            suggestionsKey = sk;
            suggestions.Children.Clear();
            if (list.Count > 0)
            {
                suggestions.Children.Add(Kit.Text("recent", Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None));
                for (int i = 0; i < list.Count; i++)
                {
                    var entry = list[i];
                    var chip = new GitCoauthorChip(entry, ringed: i == 0) { ToolTip = "Add " + entry };
                    Kit.OnClick(chip, () => this.state?.AddGitCoauthor(entry));
                    suggestions.Children.Add(chip);
                }
            }
            suggestions.Visibility = list.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        if (draft.CoauthorRejects > rejectsBefore && !Theme.Motion.ReduceMotion) Transitions.Shake(coauthorBox);
        rejectsBefore = draft.CoauthorRejects;

        failureText.Text = failure ?? "";
        failureText.ToolTip = failure;

        // The bottom row: "Commit 3 ⏎" (or the running pill), "@ Co-author", Cancel.
        bool enabled = state.GitCanCommit;
        var key = committing ? "running" : "commit|" + state.GitCheckedFiles.Count + "|" + enabled;
        if (key != commitKey)
        {
            bool animate = commitKey is not null;
            commitKey = key;
            foreach (FrameworkElement old in commitHost.Children.Cast<FrameworkElement>().ToList())
            {
                if (animate) Transitions.Remove(old, TransitionSpec.Opacity(Theme.Motion.StageSwap, Theme.Motion.StageSwap), () => commitHost.Children.Remove(old));
                else commitHost.Children.Remove(old);
            }
            FrameworkElement next = committing
                ? new GitRunningPill(GitOp.Commit.RunningTitle)
                : new ActionSegment("Commit", Theme.Keys.Enter, ActionRole.Allow, state.RunGitCommit, state.GitCheckedFiles.Count)
                {
                    Enabled = enabled,
                    Opacity = enabled ? 1 : Theme.Opacity.Disabled,
                    ToolTip = state.GitCommitButtonTitle,
                };
            commitHost.Children.Add(next);
            if (animate) Transitions.Insert(next, TransitionSpec.Opacity(Theme.Motion.StageSwap, Theme.Motion.StageSwap));
        }
        int coauthorCount = draft.Coauthors.Count;
        var title = Theme.Keys.Coauthor + " " + (coauthorCount == 0 ? "Co-author" : coauthorCount.ToString());
        if (title != coauthorTitle)
        {
            coauthorTitle = title;
            coauthorHost.Children.Clear();
            coauthorHost.Children.Add(new ActionSegment(title, null, ActionRole.Neutral, () => this.state?.ToggleGitCoauthors()));
        }
        if (coauthorHost.Children.Count > 0 && coauthorHost.Children[0] is FrameworkElement pill)
            pill.ToolTip = draft.CoauthorsShown ? "Hide the co-authors" : "Add a co-author (a Co-authored-by trailer)";

        // The parts come and go with `shown`, each on its own beat; the summary's box is
        // travelled in by GitTab (the dock's box, arrived).
        bool first = shownBefore is null;
        bool changed = shownBefore != shown;
        shownBefore = shown;
        if (changed)
        {
            if (shown)
            {
                Show(SummaryBox, null, first);
                Transitions.FadeIn((UIElement)((Border)SummaryBox).Child);
                Show(descriptionBox, Theme.Motion.StageRise(0), first);
                if (draft.CoauthorsShown) Show(coauthors, Theme.Motion.StageRise(1), first);
                Show(bottom, Theme.Motion.StageRise(2), first);
            }
            else
            {
                foreach (var part in new FrameworkElement[] { SummaryBox, descriptionBox, coauthors, bottom, failureText })
                {
                    if (part.Visibility != Visibility.Visible) continue;
                    var p = part;
                    // Out at once with the pane swap's drop, so esc feels instant.
                    if (first) p.Visibility = Visibility.Collapsed;
                    else Transitions.Remove(p, Theme.Motion.StageRise(0), () => { if (shownBefore == false) p.Visibility = Visibility.Collapsed; });
                }
            }
        }
        if (shown && !changed && draft.CoauthorsShown != coauthorsShownBefore)
        {
            if (draft.CoauthorsShown) Show(coauthors, Theme.Motion.StageRise(1), false);
            else Transitions.Remove(coauthors, Theme.Motion.StageRise(1), () => { if (this.state?.GitDraft.CoauthorsShown == false) coauthors.Visibility = Visibility.Collapsed; });
        }
        coauthorsShownBefore = draft.CoauthorsShown;
        if (shown)
        {
            bool showFailure = failure is not null;
            if (showFailure && failureText.Visibility != Visibility.Visible) Show(failureText, Theme.Motion.PaneSwapTransition, false);
            else if (!showFailure) failureText.Visibility = Visibility.Collapsed;
            // The field the draft names takes the keys once the box is in.
            if (draft.Focus is { } focus)
            {
                var box = focus switch
                {
                    GitDraftFocus.Summary => summary.Box,
                    GitDraftFocus.Description => description.Box,
                    _ => coauthorField.Box,
                };
                if (!box.IsKeyboardFocused) Dispatcher.BeginInvoke(() => { if (shownBefore == true && box.IsVisible) box.Focus(); });
            }
        }
    }

    private static void Show(FrameworkElement part, TransitionSpec? spec, bool first)
    {
        part.Visibility = Visibility.Visible;
        if (!first && spec is not null) Transitions.Insert(part, spec);
        else
        {
            part.Opacity = 1;
            Transitions.Snap(part, OpacityProperty, 1);
        }
    }
}

/// "Ada Lovelace <ada@x.dev> ×": one co-author, mono on a quiet chip; × removes it. A
/// suggestion has no × and the first carries a ring.
public sealed class GitCoauthorChip : Border
{
    public GitCoauthorChip(string entry, bool ringed = false, Action? onRemove = null)
    {
        var row = new RowStack(Theme.Size.SpaceXS, new TrimText(entry, Theme.Fonts.MonoCaption, Theme.Brushes.GitCoauthorChipText, TrimMode.Middle));
        if (onRemove is not null)
        {
            var remove = Kit.Text(Theme.Glyphs.Remove, Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None);
            remove.ToolTip = "Remove";
            remove.Background = Kit.HitFill;
            Kit.OnClick(remove, onRemove);
            row.Children.Add(remove);
        }
        Child = row;
        Padding = new Thickness(Theme.Size.GitChipHPadding, Theme.Size.GitChipVPadding, Theme.Size.GitChipHPadding, Theme.Size.GitChipVPadding);
        CornerRadius = new CornerRadius(Theme.Radius.Keycap);
        Background = Theme.Brushes.GitCoauthorChipFill;
        BorderBrush = ringed ? Theme.Brushes.GitSuggestionRing : null;
        BorderThickness = new Thickness(ringed ? Theme.Size.GitSuggestionRing : 0);
        VerticalAlignment = VerticalAlignment.Center;
    }
}
