// RequestCards.cs
// Port of Sources/notchcode/Features/Requests/RequestCards.swift.
// What the well shows when Claude is blocked on the owner: a permission, a commit, a plan,
// or (read-only) a question. The answers live in the strip's action segments; the well shows
// what is being asked, the diff behind it, and the way out to the terminal.

using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Notchcode.Features.Files;
using Notchcode.State;
using Notchcode.UI;
using Notchcode.UI.Diff;

namespace Notchcode.Features.Requests;

internal static class RequestText
{
    public const string Footer = "At 0:00 the terminal asks instead. Nothing is denied for you.";
}

/// "At 0:00 the terminal asks instead…" and "Open in Windows Terminal ↗".
internal sealed class RequestFooter : RowStack
{
    public RequestFooter(AppState state, string sessionId)
    {
        Spacing = Theme.Size.SpaceM;
        var session = state.Session(sessionId);
        var text = new TrimText(RequestText.Footer, Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        Children.Add(Kit.Flex(text));
        Children.Add(Kit.Priority(new TeleportLink($"Open in {state.TerminalName(session)}", () => state.Teleport(session)), 1));
    }
}

/// "+12 −3 · Show changes   D": opens the request's diff inside the well.
internal sealed class ShowChangesRow : Border
{
    public ShowChangesRow(FileChange file, bool open, Action action)
    {
        var words = new RowStack(0, new DiffCounts(file.Added, file.Removed),
            Kit.Text(Theme.Glyphs.Separator + (open ? "Hide changes" : "Show changes"), Theme.Fonts.Caption, Theme.Brushes.InkSecondary));
        Child = new RowStack(Theme.Size.SpaceM, new RowChevron(open, width: null), words, Kit.Spacer(Theme.Size.SpaceM), new InlineKeycap(Theme.Keys.Diff));
        Padding = new Thickness(Theme.Size.RowHPadding, Theme.Size.RowVPadding, Theme.Size.RowHPadding, Theme.Size.RowVPadding);
        Background = Kit.HitFill;
        Kit.OnClick(this, action);
    }
}

/// The request's title with the countdown ring on the right.
internal sealed class RequestTitle : RowStack
{
    public RequestTitle(PendingRequest request, int lines = 1)
    {
        Spacing = Theme.Size.SpaceM;
        var title = Kit.Wrapped(request.Title, Theme.Fonts.Hero, Theme.Brushes.Ink, maxLines: lines);
        if (lines == 1) title.TextWrapping = TextWrapping.NoWrap;
        Children.Add(Kit.Flex(title));
        Children.Add(new DeadlineCountdown(request, Theme.Size.CountdownRingLarge, Theme.Fonts.BodyMedium));
    }
}

/// A Bash command in full: it wraps, is never cut, and scrolls inside its box when taller
/// than the card allows, with "… 3 more lines · scroll" while more is below. Allow runs all
/// of it, so the owner must be able to read all of it.
internal sealed class CommandBox : Border
{
    private readonly ScrollViewer scroll = ScrollExtras.Make(horizontal: false);
    private readonly TextBlock command;
    private readonly TextBlock note;

    public CommandBox(string text, string tool)
    {
        command = Kit.Wrapped(text, Theme.Fonts.Mono, Theme.Brushes.Ink);
        command.TextTrimming = TextTrimming.None;
        scroll.Content = command;
        scroll.MaxHeight = Theme.Size.RequestDiffMaxHeight;
        note = Kit.Text("", Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
        note.HorizontalAlignment = HorizontalAlignment.Left;
        var row = new RowStack(Theme.Size.SpaceM, Kit.Flex(scroll), new ToolChip(tool) { VerticalAlignment = VerticalAlignment.Top }) { Cross = StackCross.Start };
        var column = new ColumnStack(Theme.Size.SpaceS, Kit.Priority(row, -1), note);
        Child = new InsetGroup(column);
        scroll.ScrollChanged += (_, _) => UpdateNote();
        Loaded += (_, _) => UpdateNote();
    }

    /// "… 3 more lines · scroll" while text is below the box, "end of command" once scrolled
    /// to the bottom of a command that did not fit, nothing when it all fits.
    private void UpdateNote()
    {
        double content = scroll.ExtentHeight, viewport = scroll.ViewportHeight;
        if (viewport <= 0 || Math.Round(content) <= Math.Round(viewport))
        {
            note.Visibility = Visibility.Collapsed;
            return;
        }
        note.Visibility = Visibility.Visible;
        double lineHeight = Theme.Fonts.Mono.Size * Theme.Fonts.Mono.Family.LineSpacing;
        int below = (int)Math.Ceiling((content - viewport - scroll.VerticalOffset) / lineHeight);
        note.Text = below <= 0 ? "end of command" : Format.MoreLines(below) + Theme.Glyphs.Separator + "scroll";
    }
}

/// Every rule Always would add (all of them are sent back), in tertiary ink: at most
/// `alwaysRuleLines`, then "+N more".
internal sealed class AlwaysRules : StackPanel
{
    public AlwaysRules(IReadOnlyList<string> rules)
    {
        var shown = rules.Take(Theme.Limits.AlwaysRuleLines).ToList();
        for (int i = 0; i < shown.Count; i++)
        {
            var line = Kit.Text(shown[i], Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
            line.Margin = new Thickness(0, i == 0 ? 0 : Theme.Size.SpaceXS, 0, 0);
            Children.Add(line);
        }
        if (rules.Count > shown.Count)
            Children.Add(new TextBlock { Text = $"+{rules.Count - shown.Count} more", Foreground = Theme.Brushes.InkTertiary, Margin = new Thickness(0, Theme.Size.SpaceXS, 0, 0) }.Also(Theme.Fonts.Caption.Apply));
        ToolTip = string.Join("\n", rules);
    }
}

internal static class ElementExtensions
{
    public static T Also<T>(this T element, Action<T> apply)
    {
        apply(element);
        return element;
    }
}

public sealed class PermissionCard : ColumnStack
{
    /// The open diff, so ↑↓ reach it without a rebuild.
    public DiffView? Diff { get; }

    public PermissionCard(AppState state, PendingRequest request, bool animateDiff)
    {
        Spacing = Theme.Size.SpaceL;
        var file = request.Files.FirstOrDefault();
        bool open = state.RequestDiffPath(request) is not null;
        Children.Add(new RequestTitle(request));

        if (request.Tool == "Bash")
        {
            Children.Add(Kit.Priority(new CommandBox(request.Detail, request.Tool), -1));
        }
        else
        {
            var detail = Kit.Wrapped(request.Detail, Theme.Fonts.Mono, Theme.Brushes.Ink, maxLines: file is null ? 4 : 2);
            Children.Add(new InsetGroup(new RowStack(Theme.Size.SpaceM, Kit.Flex(detail), new ToolChip(request.Tool) { VerticalAlignment = VerticalAlignment.Top }) { Cross = StackCross.Start }));
        }

        if (file is not null && file.DiffLines().Count > 0)
        {
            var path = file.Path;
            Children.Add(new ShowChangesRow(file, open, () => state.ToggleRequestDiff(path))
            {
                Margin = new Thickness(0, -Theme.Size.SpaceS, 0, -Theme.Size.SpaceS),
            });
        }

        if (open && file is not null)
        {
            // Takes the room left above the footer, which never moves.
            Diff = new DiffView(file, Theme.Size.RequestDiffMaxHeight, state.RequestDiffScroll);
            Children.Add(Kit.Priority(Diff, -1));
            if (animateDiff) Transitions.Insert(Diff, Theme.Motion.RequestDiffTransition);
        }

        if (request.Reason is { Length: > 0 } reason)
            Children.Add(Kit.Wrapped(reason, Theme.Fonts.Body, Theme.Brushes.InkSecondary, maxLines: open ? 1 : 2));

        if (request.AlwaysRules.Count > 0) Children.Add(new AlwaysRules(request.AlwaysRules));

        Children.Add(Kit.Spacer());
        Children.Add(new RequestFooter(state, request.SessionId));
    }
}

public sealed class CommitCard : ColumnStack
{
    public DiffView? Diff { get; private set; }

    public CommitCard(AppState state, PendingRequest request, bool animateDiff)
    {
        Spacing = Theme.Size.SpaceL;
        var openPath = state.RequestDiffPath(request);
        Children.Add(new RequestTitle(request, lines: openPath is null ? 2 : 1));

        var list = new ColumnStack { Spacing = Theme.Size.SpaceS, Margin = new Thickness(-Theme.Size.SpaceS) };
        if (request.Files.Count == 0)
        {
            list.Children.Add(Kit.Wrapped(request.Detail, Theme.Fonts.MonoCaption, Theme.Brushes.InkSecondary, maxLines: 3));
        }
        else
        {
            var shown = request.Files.Take(Theme.Limits.CommitMaxFileRows).ToList();
            for (int index = 0; index < shown.Count; index++)
            {
                // A file row like the Changes tool's; a click (or D on the cursor row) opens its diff under it.
                var file = shown[index];
                bool cursorShown = request.Files.Count > 1 && file.DiffLines().Count > 0;
                int i = index;
                var row = new FileDiffRow(file, openPath == file.Path, cursorShown && state.RequestRowCursor == index,
                    () => { state.RequestRowCursor = i; state.ToggleRequestDiff(file.Path); },
                    () =>
                    {
                        Diff = new DiffView(file, Theme.Size.RequestDiffMaxHeight, state.RequestDiffScroll);
                        if (animateDiff) Transitions.Insert(Diff, Theme.Motion.RequestDiffTransition);
                        return Diff;
                    },
                    spacing: 0, disabledWithoutDiff: true);
                list.Children.Add(openPath == file.Path ? Kit.Priority(row, -1) : row);
            }
            if (request.Files.Count > shown.Count)
            {
                var more = Kit.Text($"{request.Files.Count - shown.Count} more files", Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
                more.Margin = new Thickness(Theme.Size.RowHPadding, 0, Theme.Size.RowHPadding, 0);
                list.Children.Add(more);
            }
        }
        var group = new InsetGroup(list);
        Children.Add(openPath is null ? group : Kit.Priority(group, -1));

        var bottom = new RowStack { Spacing = Theme.Size.SpaceM };
        bottom.Children.Add(Kit.Flex(new TrimText(request.Detail, Theme.Fonts.MonoSmall, Theme.Brushes.InkTertiary)));
        if (request.Files.Any(f => f.DiffLines().Count > 0))
        {
            bottom.Children.Add(new RowStack(Theme.Size.SpaceS,
                Kit.Text(openPath is null ? "Show changes" : "Hide changes", Theme.Fonts.Caption, Theme.Brushes.InkTertiary, TextTrimming.None),
                new InlineKeycap(Theme.Keys.Diff)));
        }
        bottom.Children.Add(new ToolChip(request.Tool) { VerticalAlignment = VerticalAlignment.Center });
        Children.Add(bottom);

        Children.Add(Kit.Spacer());
        Children.Add(new RequestFooter(state, request.SessionId));
    }
}

/// A finished plan: its heading as the hero, the rest rendered as Markdown in a box that
/// takes the room above the footer and scrolls (↑↓ by blocks, or the wheel).
public sealed class PlanCard : ColumnStack
{
    public MarkdownView? Markdown { get; }

    public PlanCard(AppState state, PendingRequest request)
    {
        Spacing = Theme.Size.SpaceL;
        Children.Add(new RequestTitle(request));
        if (request.Detail.Length == 0)
        {
            var text = Kit.Wrapped("The plan is in the terminal.", Theme.Fonts.Body, Theme.Brushes.InkSecondary);
            text.Margin = new Thickness(Theme.Size.MarkdownPadding);
            Children.Add(Boxes.SnippetBox(text));
        }
        else
        {
            var body = HookText.PlanBody(request.Detail);
            var shown = body.Take(Theme.Limits.PlanMaxLines).ToList();
            string? footer = body.Count > shown.Count
                ? Format.MoreLines(body.Count - shown.Count) + Theme.Glyphs.Separator + "open in the terminal"
                : null;
            // Each plan starts at its top with its own scroll state.
            Markdown = new MarkdownView(scrollDriven: true) { Footer = footer, Lines = shown };
            Markdown.ApplyScroll(state.RequestDiffScroll);
            Children.Add(Kit.Priority(Markdown, -1));
        }
        Children.Add(Kit.Spacer());
        Children.Add(new RequestFooter(state, request.SessionId));
    }
}

/// Preview only: no hook can answer a question, so the one action (in the strip) is teleport.
public sealed class QuestionCard : ColumnStack
{
    public QuestionCard(AppState state, QuestionPreview question)
    {
        Spacing = Theme.Size.SpaceL;
        var session = state.Session(question.SessionId);
        Children.Add(Kit.Wrapped(question.Question, Theme.Fonts.Hero, Theme.Brushes.Ink, maxLines: 3));
        if (question.Options.Count > 0)
        {
            var options = new StackPanel();
            int i = 0;
            foreach (var option in question.Options.Take(Theme.Limits.MaxQuestionOptions))
            {
                // No keycaps: no hook can answer a question, so the options are read-only.
                options.Children.Add(new Border
                {
                    Child = Kit.Text(option, Theme.Fonts.Body, Theme.Brushes.InkSecondary),
                    Padding = new Thickness(Theme.Size.RowHPadding, Theme.Size.RowVPadding, Theme.Size.RowHPadding, Theme.Size.RowVPadding),
                    CornerRadius = new CornerRadius(Theme.Radius.Row),
                    Background = Theme.Brushes.Inset,
                    Margin = new Thickness(0, i++ == 0 ? 0 : Theme.Size.SpaceS, 0, 0),
                });
            }
            Children.Add(options);
        }
        Children.Add(Kit.Spacer());
        Children.Add(new RowStack(Theme.Size.SpaceM,
            Kit.Flex(new TrimText("Only the terminal can take the answer.", Theme.Fonts.Caption, Theme.Brushes.InkTertiary)),
            new TeleportLink($"Answer in {state.TerminalName(session)}", () => state.Teleport(session))));
    }
}

/// The well's content while a request or the question shows: the card for `CardContent`,
/// rebuilt when the request, its open diff or the commit card's cursor changes, and kept
/// when only ↑↓ move its box (`RequestDiffScroll`).
public sealed class RequestCardHost : Grid
{
    private readonly AppState state;
    private string? key;
    private string? openBefore;
    private UIElement? card;
    private bool pending;

    public RequestCardHost(AppState state)
    {
        this.state = state;
        Loaded += (_, _) =>
        {
            state.PropertyChanged += OnStateChanged;
            Render();
        };
        Unloaded += (_, _) => state.PropertyChanged -= OnStateChanged;
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppState.RequestDiffScroll))
        {
            switch (card)
            {
                case PermissionCard p when p.Diff is not null: p.Diff.Scroll = state.RequestDiffScroll; break;
                case CommitCard c when c.Diff is not null: c.Diff.Scroll = state.RequestDiffScroll; break;
                case PlanCard plan when plan.Markdown is not null: plan.Markdown.ApplyScroll(state.RequestDiffScroll); break;
            }
            return;
        }
        if (pending) return;
        pending = true;
        Dispatcher.BeginInvoke(() => { pending = false; Render(); }, DispatcherPriority.Render);
    }

    public void Render()
    {
        var content = state.CardContent;
        string next;
        string? open = null;
        switch (content)
        {
            case CardContent.Request r:
                open = state.RequestDiffPath(r.Value);
                next = "r|" + r.Value.Id + "|" + open + "|" + state.RequestRowCursor;
                break;
            case CardContent.Question q:
                next = "q|" + q.Value.Question + "|" + q.Value.SessionId;
                break;
            default:
                next = "";
                break;
        }
        if (next == key) return;
        key = next;
        bool animateDiff = open is not null && open != openBefore;
        openBefore = open;
        Children.Clear();
        card = content switch
        {
            CardContent.Request { Value.Kind: PendingRequestKind.Commit } r => new CommitCard(state, r.Value, animateDiff),
            CardContent.Request { Value.Kind: PendingRequestKind.Plan } r => new PlanCard(state, r.Value),
            CardContent.Request r => new PermissionCard(state, r.Value, animateDiff),
            CardContent.Question q => new QuestionCard(state, q.Value),
            _ => null,
        };
        if (card is not null) Children.Add(card);
    }
}
