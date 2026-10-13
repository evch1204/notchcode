// PanesHarness.cs
// A debug harness for wave 1c's panes (Sessions, Changes, Files, Usage): each pane in a plain
// window at the card's well size on the black, with sample data, rendered to a PNG after its
// motion has settled. Run by the test project's PanesHarnessTests when NOTCHCODE_PANES_OUT
// names a folder (`$env:NOTCHCODE_PANES_OUT="C:\tmp\panes"; dotnet test --filter PanesHarness`).
// The Files pane reads this repository's own tree, so it shows real files. Not part of the
// app's startup; wave 2's demo replaces it.

using System.Collections.Immutable;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Notchcode.Core;
using Notchcode.Features.Changes;
using Notchcode.Features.Files;
using Notchcode.Features.Sessions;
using Notchcode.Features.Usage;
using Notchcode.State;
using Notchcode.UI;

using Notchcode.UI.Diff;


namespace Notchcode.Features;

public static class PanesHarness
{
    /// The well's content width on the 640 pt card (PLAN, Direction G: "Inside the well (576 × 334)").
    public const double WellWidth = 576;

    /// Renders every pane with sample data into `outDir` as PNGs. Must run on an STA thread.
    /// `repoRoot` is the folder the Files pane shows (this repository when null).
    public static List<string> RenderAll(string outDir, string? repoRoot = null)
    {
        Directory.CreateDirectory(outDir);
        Theme.Motion.ReduceMotionOverride = false;
        var written = new List<string>();
        var root = repoRoot ?? FindRepoRoot();

        // Sessions.
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Sessions;
            state.SessionCursor = 1;
            written.Add(Render(new SessionsTab(state), Theme.Size.SessionsCardHeight, Path.Combine(outDir, "sessions.png")));
        }

        // Changes: the timeline alone, then with a chip's diff pane open, then With edits.
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Changes;
            state.RowCursor = 1;
            written.Add(Render(new ChangesTab(state), Theme.Size.ChangesCardHeight, Path.Combine(outDir, "changes.png")));
        }
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Changes;
            var items = state.ChangesCursorItems;
            int index = items.FindIndex(i => i is ChangesItem.Chip);
            state.RowCursor = Math.Max(0, index + 1);
            if (items[state.RowCursor] is ChangesItem.Chip chip) state.SelectChangesChip(chip.Key);
            written.Add(Render(new ChangesTab(state), Theme.Size.ChangesCardHeight, Path.Combine(outDir, "changes-pane.png")));
        }
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Changes;
            var group = state.ChangesBlocks.OfType<ChangesBlock.Quiet>().First();
            state.ToggleChangesGroup(group.GroupId);
            written.Add(Render(new ChangesTab(state), Theme.Size.ChangesCardHeight, Path.Combine(outDir, "changes-unfolded.png")));
        }

        // Files: a code file with this session's changes tinted, then a Markdown file rendered.
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Files;
            OpenFile(state, root, "windows/src/Notchcode.App/Core/Format.cs");
            written.Add(Render(new FilesTab(state), Theme.Size.FilesCardHeight, Path.Combine(outDir, "files-code.png")));
        }
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Files;
            OpenFile(state, root, "windows/PLAN.md");
            written.Add(Render(new FilesTab(state), Theme.Size.FilesCardHeight, Path.Combine(outDir, "files-markdown.png")));
        }

        // Usage: everything known, then nothing known.
        {
            var state = SampleState(root);
            state.SelectedTab = CardTab.Usage;
            written.Add(Render(new UsageTab(state), Theme.Size.UsageCardHeight, Path.Combine(outDir, "usage.png")));
        }
        {
            var state = new AppState(new Preferences(), savesPrefs: false) { ReadsLocalFiles = false };
            written.Add(Render(new UsageTab(state), Theme.Size.UsageCardHeight, Path.Combine(outDir, "usage-empty.png")));
        }
        return written;
    }

    /// The pane in a borderless window off screen, on the well's colour over black, at the
    /// well's width and the tool's pane height; its motion settles, then it is saved.
    private static string Render(FrameworkElement pane, double cardHeight, string path)
    {
        double height = Theme.Size.TabPaneHeight(cardHeight);
        var well = new Border
        {
            Background = Theme.Brushes.Well,
            Child = pane,
            Width = WellWidth,
            Height = height,
        };
        var host = new Border { Background = Theme.Brushes.Notch, Child = well };
        var window = new Window
        {
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            ShowActivated = false,
            SizeToContent = SizeToContent.WidthAndHeight,
            Left = -20000,
            Top = -20000,
            Background = Brushes.Black,
            Content = host,
        };
        window.Show();
        Wait(1.4);
        var dpi = 2.0;
        var bitmap = new RenderTargetBitmap((int)(WellWidth * dpi), (int)(height * dpi), 96 * dpi, 96 * dpi, PixelFormats.Pbgra32);
        bitmap.Render(host);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var file = File.Create(path)) encoder.Save(file);
        window.Close();
        return path;
    }

    /// Pumps the dispatcher for `seconds`, so layout, timers and animations run.
    private static void Wait(double seconds)
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
    }

    private static string FindRepoRoot()
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !Directory.Exists(Path.Combine(dir, "windows")))
            dir = Path.GetDirectoryName(dir.TrimEnd('\\'));
        return dir ?? Environment.CurrentDirectory;
    }

    private static void OpenFile(AppState state, string root, string path)
    {
        var tree = RepoFiles.Tree(root);
        var preview = RepoFiles.Preview(root, path);
        state.FilesTool = state.FilesTool with
        {
            RepoTrees = state.FilesTool.RepoTrees.SetItem(root, tree),
            OpenedFile = state.FilesTool.OpenedFile.SetItem("harbor", path),
            TreeCursor = state.FilesTool.TreeCursor.SetItem("harbor", path),
            Previews = state.FilesTool.Previews.SetItem(AppState.PreviewKey(root, path), new LoadedPreview { Preview = preview }),
            // Open the folders down to the file.
            TreeToggled = state.FilesTool.TreeToggled.SetItem("harbor",
                [.. Ancestors(path).Where(p => AppState.Depth(p) > 0)]),
        };
    }

    private static IEnumerable<string> Ancestors(string path)
    {
        var parent = AppState.Parent(path);
        while (parent is not null)
        {
            yield return parent;
            parent = AppState.Parent(parent);
        }
    }

    // MARK: Sample data

    private static DateTime Ago(double minutes) => DateTime.UtcNow.AddMinutes(-minutes);

    /// Two repositories, three sessions: harbor working in bypass with agents, quartz waiting
    /// on a permission, orbit idle. harbor's cwd is `root`, so Files reads a real tree.
    public static AppState SampleState(string root)
    {
        var state = new AppState(new Preferences(), savesPrefs: false) { ReadsLocalFiles = false };
        var harbor = new Session
        {
            Id = "harbor", Cwd = root, WorktreeName = "harbor", RepoName = "lumen", Branch = "feature/cart",
            State = SessionState.Working, Verb = "Editing", StartedAt = Ago(207), LastEventAt = Ago(0.2),
            PermissionMode = "bypassPermissions", TermProgram = "WindowsTerminal",
        };
        var quartz = new Session
        {
            Id = "quartz", Cwd = @"C:\work\lumen-quartz", WorktreeName = "quartz", RepoName = "lumen", Branch = "main",
            State = SessionState.NeedsYou, StartedAt = Ago(40), LastEventAt = Ago(12), PermissionMode = "plan",
        };
        var orbit = new Session
        {
            Id = "orbit", Cwd = @"C:\work\orbit", WorktreeName = "orbit", Branch = "main",
            State = SessionState.Idle, StartedAt = Ago(90), LastEventAt = Ago(55),
        };
        state.Sessions = [harbor, quartz, orbit];
        state.Pending =
        [
            new PendingRequest
            {
                Id = "r1", Kind = PendingRequestKind.Permission, SessionId = "quartz", Tool = "Bash",
                Title = "Run the tests?", Detail = "npm test", ReceivedAt = Ago(0.1), Deadline = DateTime.UtcNow.AddSeconds(50),
            },
        ];
        state.FocusedSessionId = "harbor";
        state.TurnTitles = state.TurnTitles.SetItem("harbor", "Refactor the cart totals so tax is computed once")
            .SetItem("quartz", "Add retry to the orders API with exponential backoff");
        state.TurnStarts = state.TurnStarts.SetItem("harbor", Ago(4.2));
        state.Agents = state.Agents.SetItem("harbor",
        [
            new Agent { Id = "a1", SessionId = "harbor", Type = "Explore", Description = "Reading api/orders.ts", StartedAt = Ago(1.5) },
            new Agent { Id = "a2", SessionId = "harbor", Type = "general-purpose", Description = "Update the tax tests", StartedAt = Ago(30), EndedAt = Ago(26) },
            new Agent { Id = "a3", SessionId = "harbor", Type = "fork", Description = "Check rounding", StartedAt = Ago(20), EndedAt = Ago(19) },
        ]);
        state.Statusline = state.Statusline
            .SetItem("harbor", new StatuslineFacts
            {
                Model = "claude-opus-5-5", DisplayName = "Opus 5.5", Effort = "high", ThinkingEnabled = true,
                ContextPercent = 36, ContextUsed = 357_000, ContextLimit = 1_000_000, Exceeds200k = true, CostUSD = 1.42,
                DurationMs = 12_420_000, LinesAdded = 2351, LinesRemoved = 147,
                CurrentUsage = new TokenUsage { Input = 4_100, CacheRead = 331_000, CacheWrite = 21_900, Output = 900 },
                UpdatedAt = Ago(3),
            })
            .SetItem("quartz", new StatuslineFacts { Model = "claude-sonnet-5", UpdatedAt = Ago(12) })
            .SetItem("orbit", new StatuslineFacts { Model = "claude-haiku-5", UpdatedAt = Ago(55) });

        state.TurnsBySession = state.TurnsBySession.SetItem("harbor", SampleTurns());
        state.PlanUsage = new PlanUsage
        {
            FetchedAt = Ago(8),
            ModelWeeks = [new ModelWeek { Name = "Fable", Percent = 41, ResetsAt = DateTime.UtcNow.AddDays(3) }],
            WeekBreakdown = [new NamedShare { Name = "Claude Code", Percent = 98 }, new NamedShare { Name = "Chats", Percent = 2 }],
        };
        state.Usage = state.Usage with
        {
            FiveHourPercent = 61, FiveHourResetsAt = DateTime.UtcNow.AddMinutes(112),
            WeekPercent = 93, WeekResetsAt = DateTime.UtcNow.AddDays(2),
        };
        state.LimitsUpdatedAt = Ago(3);
        state.UsageBehaviors = new UsageBehaviors
        {
            Day = new UsageBehaviorPeriod
            {
                Title = "Last 24h", Requests = 155, Sessions = 2,
                Lines = ["94% of your usage came from subagent-heavy sessions", "82% of your usage was at >150k context", "Top subagents: general-purpose 34%, fork 5%"],
            },
            Week = new UsageBehaviorPeriod { Title = "Last 7d", Requests = 1204, Sessions = 19 },
        };
        state.RecomputeUsage();
        return state;
    }

    private static ImmutableList<TranscriptTurn> SampleTurns()
    {
        static FileChange File(string path, int added, int removed, string? agent = null, string kind = "edit")
        {
            var patch = new List<DiffLine> { new() { Kind = DiffLineKind.Hunk, Text = "@@ -40,7 +40,9 @@ export function total(cart) {" } };
            int oldLine = 40, newLine = 40;
            patch.Add(new() { Kind = DiffLineKind.Context, Text = "  const items = cart.items;", OldLine = oldLine++, NewLine = newLine++ });
            for (int i = 0; i < Math.Min(removed, 3); i++)
                patch.Add(new() { Kind = DiffLineKind.Removed, Text = $"  let sum = items.reduce((a, b) => a + b.price * (1 + TAX), {i});", OldLine = oldLine++ });
            for (int i = 0; i < Math.Min(added, 5); i++)
                patch.Add(new() { Kind = DiffLineKind.Added, Text = $"  const subtotal{i} = items.reduce((a, b) => a + b.price, 0);", NewLine = newLine++ });
            patch.Add(new() { Kind = DiffLineKind.Context, Text = "  return round(subtotal * (1 + TAX));", OldLine = oldLine, NewLine = newLine });
            return new FileChange { Path = path, Added = added, Removed = removed, Kind = kind, Patch = patch, AgentId = agent };
        }
        TranscriptTurn Turn(string id, string prompt, double startMinutes, double? endMinutes, params FileChange[] files) => new()
        {
            Id = id, Prompt = prompt, StartedAt = Ago(startMinutes), EndedAt = endMinutes is double e ? Ago(e) : null, Files = files,
            Tokens = new TokenUsage { Input = 12_000, Output = 3_000, CacheRead = 220_000, CacheWrite = 18_000 }, Model = "claude-opus-5-5",
        };
        return
        [
            Turn("t1", "Look around the cart module and tell me how totals are computed", 207, 204),
            Turn("t2", "Move the tax rate into config and update every caller", 190, 176,
                File("src/cart/totals.ts", 53, 19), File("src/config/tax.ts", 12, 0, kind: "new"), File("test/cart/totals.test.ts", 40, 8, agent: "a2")),
            Turn("t3", "Why is the rounding off by a cent on the second item?", 150, 149),
            Turn("t4", "Should we round per line or on the total? Pick one", 140, 139),
            Turn("t5", "Round on the total and fix the tests that relied on per-line rounding, then run the whole suite", 120, 96,
                File("src/cart/round.ts", 18, 22), File("test/cart/round.test.ts", 31, 4, agent: "a3"), File("scripts/check-rounding.sh", 6, 0, kind: "shell"),
                File("src/cart/TotalsCalculatorWithAVeryLongName.ts", 3, 1)),
            Turn("t6", "Refactor the cart totals so tax is computed once", 4.2, null, File("src/cart/totals.ts", 9, 14)),
        ];
    }
}
