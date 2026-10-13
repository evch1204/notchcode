// DiffView.cs
// Port of Sources/notchcode/UI/Diff/DiffView.swift.
// A file's diff as Claude Code recorded it: a rounded box, two dim line-number columns
// (old, new), then the line with its +/− prefix, in the mono size the Files preview uses.
// Added rows green on a faint green, removed red on a faint red, context grey, hunk
// headers blue. Lines never wrap. In this box they never scroll sideways either: long ones
// are clipped (the Git tool's rows scroll sideways instead). Scrolls
// vertically inside a capped height, with "… 9 more lines · scroll" at the bottom of the
// box while more is below. The word highlights inside paired −/+ lines are
// Core/Diff/WordDiff.cs.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.UI.Diff;

public static class DiffLineStyle
{
    /// The lines a diff shows: the whole patch, or the snippet when no patch was recorded.
    /// (Swift's `AppState.diffLines`, which lives with the Changes tool; here so every diff
    /// view reads one rule.)
    public static IReadOnlyList<DiffLine> DiffLines(this FileChange file) => file.Patch.Count == 0 ? file.Snippet : file.Patch;

    extension(DiffLine line)
    {
        /// The old file's number: a removed or context line has one.
        public int? OldNumber() => line.Kind is DiffLineKind.Removed or DiffLineKind.Context ? line.OldLine : null;

        /// The new file's number: an added or context line has one.
        public int? NewNumber() => line.Kind is DiffLineKind.Added or DiffLineKind.Context ? line.NewLine : null;

        public string Prefix() => line.Kind switch
        {
            DiffLineKind.Added => Theme.Glyphs.DiffAdded,
            DiffLineKind.Removed => Theme.Glyphs.DiffRemoved,
            DiffLineKind.Context => Theme.Glyphs.DiffContext,
            _ => "",
        };

        public Brush TextBrush() => line.Kind switch
        {
            DiffLineKind.Added => Theme.Brushes.Green,
            DiffLineKind.Removed => Theme.Brushes.Red,
            DiffLineKind.Context => Theme.Brushes.DiffText,
            _ => Theme.Brushes.DiffHunk,
        };

        public Brush? Background() => line.Kind switch
        {
            DiffLineKind.Added => Theme.Brushes.DiffAddedBackground,
            DiffLineKind.Removed => Theme.Brushes.DiffRemovedBackground,
            _ => null,
        };

        public Brush WordBackground() => line.Kind == DiffLineKind.Added ? Theme.Brushes.DiffAddedWord : Theme.Brushes.DiffRemovedWord;

        /// The prefix and the text, the words in `words` on the word tint. Tabs show as four spaces.
        public TextBlock StyledText(IReadOnlyList<(int Start, int End)> words)
        {
            var block = new TextBlock { Foreground = line.TextBrush(), TextWrapping = TextWrapping.NoWrap };
            Theme.Fonts.MonoSmall.Apply(block);
            block.Inlines.Add(new Run(line.Prefix()));
            var text = line.Text;
            int cursor = 0;
            foreach (var (start, end) in words)
            {
                if (start < cursor || end > text.Length) continue;
                if (start > cursor) block.Inlines.Add(new Run(Expand(text[cursor..start])));
                block.Inlines.Add(new Run(Expand(text[start..end])) { Background = line.WordBackground() });
                cursor = end;
            }
            if (cursor < text.Length) block.Inlines.Add(new Run(Expand(text[cursor..])));
            return block;
        }
    }

    private static string Expand(string s) => s.Contains('\t') ? s.Replace("\t", "    ") : s;
}

/// A file's diff in a rounded box that scrolls vertically inside a capped height; ↑↓ arrive
/// as line steps inside a request card.
public sealed class DiffView : Border
{
    private readonly FileChange file;
    private readonly IReadOnlyList<DiffLine> lines;
    private readonly double? maxHeight;
    private readonly ScrollViewer scroll = ScrollExtras.Make(horizontal: false);
    private readonly TextBlock? note;
    private readonly bool overflows;
    private RequestDiffScroll? scrollCommand;

    /// `maxHeight`: inside a request card the diff takes what room is left, up to this,
    /// instead of a fixed height. `scroll`: inside a request card ↑↓ arrive here as line steps.
    public DiffView(FileChange file, double? maxHeight = null, RequestDiffScroll? scroll = null)
    {
        this.file = file;
        this.maxHeight = maxHeight;
        scrollCommand = scroll;
        // `.snippetBox()`: the inset fill at the snippet radius, the content clipped to it.
        Background = Theme.Brushes.Inset;
        CornerRadius = new CornerRadius(Theme.Radius.Snippet);
        Boxes.ClipToRounded(this, Theme.Radius.Snippet);
        lines = file.DiffLines();
        double contentHeight = lines.Count * Theme.Size.DiffLineHeight;
        overflows = contentHeight > (maxHeight ?? Theme.Size.DiffMaxHeight);

        var stack = new StackPanel();
        foreach (var line in lines) stack.Children.Add(CodeLineRow.For(line));
        this.scroll.Content = stack;
        if (maxHeight is { } max)
        {
            this.scroll.MinHeight = Math.Min(contentHeight, Theme.Size.RequestDiffMinHeight);
            this.scroll.MaxHeight = Math.Min(contentHeight, max);
        }
        else
        {
            this.scroll.Height = Math.Min(contentHeight, Theme.Size.DiffMaxHeight);
        }

        var column = new ColumnStack { Margin = new Thickness(0, Theme.Size.PreviewVPadding, 0, Theme.Size.PreviewVPadding) };
        Kit.Priority(this.scroll, -1);
        column.Children.Add(this.scroll);
        if (overflows || file.PatchTruncated)
        {
            note = Kit.Text("", Theme.Fonts.Caption, Theme.Brushes.InkTertiary);
            column.Children.Add(new CodeLineRow([null, null], note));
        }
        Child = column;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        this.scroll.ScrollChanged += (_, _) => UpdateNote();
        Loaded += (_, _) => UpdateNote();
    }

    /// ↑↓ inside a request card: a new command (its `Seq` moved) scrolls by `Delta` lines.
    public RequestDiffScroll? Scroll
    {
        get => scrollCommand;
        set
        {
            if (value is null || value == scrollCommand) return;
            scrollCommand = value;
            int visible = Math.Max(1, (int)(scroll.ViewportHeight / Theme.Size.DiffLineHeight) - 1);
            int last = Math.Max(0, lines.Count - visible);
            int top = (int)Math.Round(scroll.VerticalOffset / Theme.Size.DiffLineHeight);
            int next = Math.Max(0, Math.Min(last, top + value.Delta));
            ScrollExtras.GlideTo(scroll, next * Theme.Size.DiffLineHeight);
        }
    }

    private void UpdateNote()
    {
        if (note is null) return;
        int top = (int)Math.Round(scroll.VerticalOffset / Theme.Size.DiffLineHeight);
        note.Text = FooterText(top, (int)(scroll.ViewportHeight / Theme.Size.DiffLineHeight));
    }

    /// "… 9 more lines · scroll" while lines are below the viewport; at the bottom,
    /// "… 212 more lines in the editor" when the patch left lines out, else "end of diff".
    private string FooterText(int topLine, int visible)
    {
        int below = Math.Max(0, lines.Count - topLine - Math.Max(0, visible));
        if (overflows && below > 0) return Format.MoreLines(below) + Theme.Glyphs.Separator + "scroll";
        if (file.PatchTruncated)
        {
            int shown = lines.Count(l => l.Kind is DiffLineKind.Added or DiffLineKind.Removed);
            int missing = Math.Max(0, file.Added + file.Removed - shown);
            return Format.MoreLines(missing) + " in the editor";
        }
        return "end of diff";
    }
}
