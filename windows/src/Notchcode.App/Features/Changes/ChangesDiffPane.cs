// ChangesDiffPane.cs
// Port of Sources/notchcode/Features/Changes/ChangesDiffPane.swift.
// The Changes tool's diff pane, right of the timeline: the Git tool's stage for one chip. A
// 20 pt header (the Ctrl B pill that hides the timeline, the file's name, its M / A badge, the
// counts, then "turn 3 · 2:32 PM" so a file edited in two turns is never confused), then the
// shared reviewer diff with its minimap. The minimap's scale is the file's length on disk
// when it is there; otherwise it draws the diff rows only. The header rises first and the
// diff one beat later; moving to another chip crossfades the diff.

using System.IO;
using System.Windows;
using System.Windows.Controls;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.UI.Diff;


namespace Notchcode.Features.Changes;

public sealed class ChangesDiffPane : Grid
{
    private readonly AppState state;
    private readonly ContentControl body = new() { Focusable = false };
    private readonly FileChange file;

    /// `number`: the turn's number, counted from the session's first. `arriving`: the pane just
    /// opened (header and diff rise in); otherwise another chip's diff crossfades in.
    public ChangesDiffPane(AppState state, TranscriptTurn turn, FileChange file, int number, bool arriving)
    {
        this.state = state;
        this.file = file;
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.ChangesRowHeight) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(Theme.Size.SpaceS) });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = Header(turn, number);
        Children.Add(header);
        SetRow(body, 2);
        Children.Add(body);
        body.Content = Content(null);

        if (arriving)
        {
            Transitions.RiseIn(header, 0);
            Transitions.RiseIn(body, 1);
        }
        else if (!Theme.Motion.ReduceMotion)
        {
            Transitions.Snap(header, OpacityProperty, 0);
            Transitions.Animate(header, OpacityProperty, Theme.Motion.PreviewFade, 1);
            Transitions.Snap(body, OpacityProperty, 0);
            Transitions.Animate(body, OpacityProperty, Theme.Motion.PreviewFade, 1);
        }
        _ = LoadLineCountAsync();
    }

    private FrameworkElement Header(TranscriptTurn turn, int number)
    {
        var grid = new Grid { Margin = new Thickness(Theme.Size.PreviewHPadding, 0, Theme.Size.PreviewHPadding, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var pill = new TreeTogglePill(state.ChangesTool.ColumnHidden, true, state.ToggleChangesColumn, "timeline");
        grid.Children.Add(pill);

        // The name keeps its room first (`.layoutPriority(1)`); the turn and time give way.
        var info = new HStack(Theme.Size.SpaceM,
            new PathLabel(file.Path).Priority(1),
            new FileKindBadge(file.Kind),
            new DiffCounts(file.Added, file.Removed),
            Ui.Text("turn " + number + Theme.Glyphs.Separator + Format.TimeOfDay(turn.StartedAt), Theme.Fonts.Caption, Theme.Brushes.InkTertiary))
        {
            Margin = new Thickness(Theme.Size.SpaceM, 0, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Grid.SetColumn(info, 1);
        grid.Children.Add(info);
        return grid;
    }

    private UIElement Content(int? lineCount)
    {
        var lines = AppState.DiffLines(file);
        if (lines.Count == 0) return new EmptyNote(file.Kind == "new" ? "Empty file" : "No text diff");
        return new ReviewerDiff(file, lines, lineCount);
    }

    /// The file on disk, from the session's folder.
    private string AbsolutePath => Paths.Absolute(file.Path, state.FocusedSession?.Cwd ?? "");

    /// Lines in the file on disk, read off the UI thread; null when it is not there (or huge).
    private async Task LoadLineCountAsync()
    {
        var path = AbsolutePath;
        var count = await Task.Run(() =>
        {
            using var stream = RegularFile.Open(path, Theme.Limits.ChangesLineCountBytes);
            if (stream is null) return (int?)null;
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().FileLines().Count;
        });
        // The minimap is scaled to the file on disk once its length is known (the diff is new, so it starts at the top).
        if (count is not null && body.Content is ReviewerDiff) body.Content = Content(count);
    }
}
