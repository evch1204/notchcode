// PanesHarnessB.cs
// Wave 1d's harness: each of its panes (Git, the request cards, Settings) in a plain WPF
// window at the well's size (576 × 334, the Changes tool's well; the request and Settings
// cards at their own heights) on black, with sample data, saved as PNGs. Not part of the app:
// nothing calls it but a scratch runner (`PanesHarnessB.Run(outDir)`). The Git scenes read
// this repository read-only (`RefreshGit()`, never the quiet fetch) or show a made-up
// snapshot; no scene runs a git write.

using System.Collections.Immutable;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Notchcode.ClaudeCode;
using Notchcode.Features.Git;
using Notchcode.Features.Requests;
using Notchcode.Features.Settings;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Features;

public static class PanesHarnessB
{
    /// The well's inside in the Changes / Git tools.
    public const double WellWidth = 576;
    public const double WellHeight = 334;

    /// Renders every scene into `outDir`. `repo` is a checkout to read for the live Git scene.
    public static void Run(string outDir, string repo)
    {
        Directory.CreateDirectory(outDir);
        Theme.Motion.ReduceMotionOverride = false;
        // NOTCHCODE_PANES_B_ONLY=plan renders only the scenes whose name contains "plan".
        var only = Environment.GetEnvironmentVariable("NOTCHCODE_PANES_B_ONLY");
        foreach (var (name, build, settle) in Scenes(repo))
        {
            if (!string.IsNullOrEmpty(only) && !name.Contains(only, StringComparison.Ordinal)) continue;
            try
            {
                var (element, height, prepare) = build();
                Capture(Path.Combine(outDir, name + ".png"), element, height, prepare, settle);
            }
            catch (Exception e)
            {
                File.WriteAllText(Path.Combine(outDir, name + ".error.txt"), e.ToString());
            }
        }
    }

    private static IEnumerable<(string Name, Func<(FrameworkElement, double, Action<FrameworkElement>?)> Build, double Settle)> Scenes(string repo)
    {
        // Git, read live from `repo`.
        yield return ("git-live", () => GitLive(repo, s => { }), 4);
        yield return ("git-live-row2", () => GitLive(repo, s => s.RowCursor = Math.Min(2, Math.Max(0, s.GitRows.Count - 1))), 4);
        // Git, a made-up checkout like the README's card-git.svg.
        yield return ("git-sample", () => GitSample(s => { }), 1.5);
        yield return ("git-sample-form", () => GitSample(s => { s.OpenGitCommitForm(); s.SetGitSummary("Split cart total into subtotal and discount"); }), 1.5);
        yield return ("git-sample-coauthors", () => GitSample(s =>
        {
            s.OpenGitCommitForm();
            s.ToggleGitCoauthors();
            s.AddGitCoauthor("Ada Lovelace <ada@lumen.dev>");
        }), 1.5);
        yield return ("git-sample-confirm", () => GitSample(s => s.PressGitSync()), 1.5);
        yield return ("git-sample-folded", () => GitSample(s => s.Prefs = s.Prefs with { FilesTreeHidden = true }), 1.5);
        yield return ("git-sample-unchecked", () => GitSample(s => s.ToggleGitFile("api/orders.ts")), 1.5);
        yield return ("git-sample-receipt", () => GitSample(s =>
        {
            s.UpdateGit(p => p with
            {
                Drafts = p.Drafts.SetItem(SampleCwd, new GitDraft { Receipt = new GitReceipt("a41c9e2", "Split cart total into subtotal and discount") }),
                Phases = p.Phases.SetItem(SampleCwd, new GitPhase.Done(GitOp.Commit, "Committed 2 files")),
            });
        }), 1.5);
        yield return ("git-sample-failed", () => GitSample(s => s.UpdateGit(p => p.SetPhase(new GitPhase.Failed(GitOp.Push, "No credentials for origin here · push from the terminal"), SampleCwd))), 1.5);
        yield return ("git-sample-clean", () => GitSample(s => s.UpdateGit(p => p with { Snapshots = p.Snapshots.SetItem(SampleCwd, p.Snapshots[SampleCwd] with { Files = [], Ahead = 0, Unpushed = 0 }) })), 1.5);
        yield return ("git-sample-picker", () => GitSample(s =>
        {
            s.UpdateGit(p => p.ResetPicker(open: true) with { Repos = SampleRepos, PickerRepo = SampleRepos[0].Id, PickerCursor = 1 });
        }), 1.5);
        yield return ("git-sample-picker-filter", () => GitSample(s =>
        {
            s.UpdateGit(p => p.ResetPicker(open: true) with { Repos = SampleRepos, PickerRepo = SampleRepos[0].Id, Filter = "cart" });
        }), 1.5);
        yield return ("git-sample-repomenu", () => GitSample(s =>
        {
            s.UpdateGit(p => p.ResetPicker(open: true) with { Repos = SampleRepos, PickerRepo = SampleRepos[0].Id, RepoMenuOpen = true });
        }), 1.5);
        // Mid-motion: the dock's box travelling up, and back; the committed rows folding; the
        // picker arriving.
        yield return ("git-motion-travel", () => GitSample(s => s.OpenGitCommitForm()), 0.1);
        yield return ("git-motion-escape", () => GitSample(s => { s.OpenGitCommitForm(); Pump(0.6); s.GitEscape(); }), 0.1);
        yield return ("git-motion-commit", () => GitSample(s =>
        {
            s.OpenGitCommitForm();
            Pump(0.6);
            var snap = s.FocusedGit!;
            s.UpdateGit(p => p with
            {
                Drafts = p.Drafts.SetItem(SampleCwd, new GitDraft { Receipt = new GitReceipt("b52d0f1", "Split cart total") }),
                Phases = p.Phases.SetItem(SampleCwd, new GitPhase.Done(GitOp.Commit, "Committed 2 files")),
                Snapshots = p.Snapshots.SetItem(SampleCwd, snap with { Files = [], Ahead = 4, Unpushed = 4 }),
            });
        }), 0.15);
        yield return ("git-motion-picker", () => GitSample(s => s.UpdateGit(p => p.ResetPicker(open: true) with { Repos = SampleRepos, PickerRepo = SampleRepos[0].Id })), 0.15);
        yield return ("git-motion-picker-close", () => GitSample(s =>
        {
            s.UpdateGit(p => p.ResetPicker(open: true) with { Repos = SampleRepos, PickerRepo = SampleRepos[0].Id });
            Pump(0.8);
            s.UpdateGit(p => p with { PickerOpen = false });
        }), 0.08);
        // The rail header's count rolling as a file is left out.
        yield return ("git-motion-count", () => GitSample(s => s.ToggleGitFile("api/orders.ts")), 0.06);
        // Request cards at their card heights (the well under the strip).
        yield return ("request-permission", () => Request(PermissionRequest(), null), 1);
        yield return ("request-permission-diff", () => Request(PermissionRequest(), s => s.ToggleRequestDiff("src/checkout/Cart.tsx")), 1);
        yield return ("request-bash", () => Request(BashRequest(), null), 1);
        yield return ("request-commit", () => Request(CommitRequest(), null), 1);
        yield return ("request-commit-diff", () => Request(CommitRequest(), s => s.ToggleRequestDiff("api/orders.ts")), 1);
        yield return ("request-plan", () => Request(PlanRequest(), null), 1.2);
        // ↓ twice moves the plan by blocks; many more reach "end of plan".
        yield return ("request-plan-down", () => Request(PlanRequest(), null, s => { s.ScrollRequestCard(s.CurrentPending!, 1); Pump(0.5); s.ScrollRequestCard(s.CurrentPending!, 1); }), 1.2);
        yield return ("request-plan-end", () => Request(PlanRequest(), null, s => { for (int i = 0; i < 12; i++) { s.ScrollRequestCard(s.CurrentPending!, 1); Pump(0.25); } }), 1.2);
        yield return ("request-plan-long", () => Request(LongPlanRequest(), null), 1.2);
        yield return ("request-plan-long-down", () => Request(LongPlanRequest(), null, s => { s.ScrollRequestCard(s.CurrentPending!, 1); Pump(0.5); s.ScrollRequestCard(s.CurrentPending!, 1); }), 1.2);
        yield return ("request-plan-long-end", () => Request(LongPlanRequest(), null, s => { for (int i = 0; i < 200; i++) { s.ScrollRequestCard(s.CurrentPending!, 1); Pump(0.03); } }), 1.5);
        yield return ("request-plan-long-up", () => Request(LongPlanRequest(), null, s =>
        {
            for (int i = 0; i < 200; i++) { s.ScrollRequestCard(s.CurrentPending!, 1); Pump(0.03); }
            s.ScrollRequestCard(s.CurrentPending!, -1);
        }), 1.5);
        yield return ("request-question", () => Question(), 1);
        yield return ("request-actions", () => Actions(), 1);
        // Settings.
        yield return ("settings", () => Settings(0), 1);
        yield return ("settings-scrolled", () => Settings(400), 1);
        yield return ("settings-bottom", () => Settings(2000), 1);
        yield return ("welcome", () => Settings(0, welcome: true), 1);
        foreach (var status in new[] { HooksInstallerStatus.Connected, HooksInstallerStatus.Partial, HooksInstallerStatus.Stale })
            yield return ("settings-" + status.ToString().ToLowerInvariant(), () => Settings(0, status: status), 1);
    }

    // MARK: - Hosting and capture

    private static void Capture(string file, FrameworkElement pane, double height, Action<FrameworkElement>? prepare, double settle)
    {
        var well = new Border
        {
            Width = WellWidth + 2 * Theme.Size.WellPadding,
            Height = height + 2 * Theme.Size.WellPadding,
            Background = Theme.Brushes.Well,
            CornerRadius = new CornerRadius(Theme.Radius.Well),
            Padding = new Thickness(Theme.Size.WellPadding),
            Child = pane,
        };
        var root = new Border { Background = Brushes.Black, Padding = new Thickness(12), Child = well };
        var window = new Window
        {
            WindowStyle = WindowStyle.None,
            ShowInTaskbar = false,
            ShowActivated = false,
            SizeToContent = SizeToContent.WidthAndHeight,
            Left = -20000,
            Top = -20000,
            Content = root,
            Background = Brushes.Black,
        };
        window.Show();
        prepare?.Invoke(pane);
        Pump(settle);
        root.UpdateLayout();
        double scale = 2;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth * scale), (int)Math.Ceiling(root.ActualHeight * scale),
            96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(root);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using (var stream = File.Create(file)) encoder.Save(stream);
        window.Close();
    }

    /// Runs the dispatcher for `seconds` so reads land and animations settle.
    private static void Pump(double seconds)
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
    }

    private static AppState NewState()
    {
        var state = new AppState(new Preferences(), savesPrefs: false);
        return state;
    }

    // MARK: - Git scenes

    private static (FrameworkElement, double, Action<FrameworkElement>?) GitLive(string repo, Action<AppState> then)
    {
        var state = NewState();
        var now = DateTime.UtcNow;
        state.Sessions = [new Session { Id = "live", Cwd = repo, WorktreeName = Path.GetFileName(repo), State = SessionState.Working, StartedAt = now, LastEventAt = now }];
        state.FocusedSessionId = "live";
        state.IsCardOpen = true;
        state.SelectedTab = CardTab.Git;
        var tab = new GitTab(state);
        return (tab, Theme.Size.TabPaneHeight(Theme.Size.GitCardHeight), _ =>
        {
            // Read only: no quiet fetch, no polling.
            state.RefreshGit();
            Pump(3);
            then(state);
        });
    }

    private const string SampleCwd = @"C:\Users\me\code\lumen-harbor";

    private static readonly ImmutableList<GitRepoGroup> SampleRepos =
    [
        new GitRepoGroup
        {
            Id = @"C:/Users/me/code/lumen",
            Name = "lumen",
            DefaultBranch = "main",
            Branches =
            [
                new GitBranch { Name = "main", Upstream = "origin/main", Place = new GitPlace.Main(@"C:/Users/me/code/lumen"), Uncommitted = 0, Ahead = 0 },
                new GitBranch { Name = "feature/cart", Upstream = "origin/feature/cart", Place = new GitPlace.Worktree(@"C:/Users/me/code/lumen-harbor"), Uncommitted = 2, Ahead = 3 },
                new GitBranch { Name = "design/toolbar", Place = GitPlace.Nowhere.Instance, Ahead = 1 },
                new GitBranch { Name = "fix/cart-rounding", Place = GitPlace.Nowhere.Instance, Ahead = 0 },
                new GitBranch { Name = "spike/orders-api", Upstream = "origin/spike/orders-api", Place = new GitPlace.Worktree(@"C:/Users/me/code/lumen-spike"), Uncommitted = 33, Ahead = 0 },
                new GitBranch { Name = "release/1.4", Upstream = "origin/release/1.4", Place = GitPlace.Nowhere.Instance, Ahead = 0 },
                new GitBranch { Name = "chore/deps", Place = GitPlace.Nowhere.Instance, Ahead = 2 },
                new GitBranch { Name = "feature/cart-discounts", Place = GitPlace.Nowhere.Instance, Ahead = 4 },
                new GitBranch { Name = "experiment/checkout-v2", Place = GitPlace.Nowhere.Instance, Ahead = 7 },
            ],
        },
        new GitRepoGroup
        {
            Id = @"C:/Users/me/code/notchcode",
            Name = "notchcode",
            DefaultBranch = "main",
            Branches = [new GitBranch { Name = "main", Upstream = "origin/main", Place = new GitPlace.Main(@"C:/Users/me/code/notchcode"), Uncommitted = 0, Ahead = 0 }],
        },
    ];

    private static (FrameworkElement, double, Action<FrameworkElement>?) GitSample(Action<AppState> then)
    {
        var state = NewState();
        state.ReadsLocalFiles = true;
        var now = DateTime.UtcNow;
        state.Sessions = [new Session { Id = "s1", Cwd = SampleCwd, WorktreeName = "harbor", RepoName = "lumen", Branch = "feature/cart", State = SessionState.Done, StartedAt = now, LastEventAt = now }];
        state.FocusedSessionId = "s1";
        state.IsCardOpen = true;
        state.SelectedTab = CardTab.Git;
        var cart = SampleCartFile();
        var orders = new FileChange
        {
            Path = "api/orders.ts",
            Added = 3,
            Removed = 1,
            Kind = "edit",
            Patch =
            [
                new DiffLine { Kind = DiffLineKind.Hunk, Text = "@@ -40,6 +40,8 @@" },
                new DiffLine { Kind = DiffLineKind.Context, Text = "export async function placeOrder(cart: Cart) {", OldLine = 40, NewLine = 40 },
                new DiffLine { Kind = DiffLineKind.Removed, Text = "  return fetch(\"/orders\", { method: \"POST\", body: json(cart) });", OldLine = 41 },
                new DiffLine { Kind = DiffLineKind.Added, Text = "  return retry(3, () =>", NewLine = 41 },
                new DiffLine { Kind = DiffLineKind.Added, Text = "    fetch(\"/orders\", { method: \"POST\", body: json(cart) }),", NewLine = 42 },
                new DiffLine { Kind = DiffLineKind.Added, Text = "  );", NewLine = 43 },
                new DiffLine { Kind = DiffLineKind.Context, Text = "}", OldLine = 42, NewLine = 44 },
            ],
        };
        var snap = new GitSnapshot
        {
            Cwd = SampleCwd,
            IsRepo = true,
            Root = "C:/Users/me/code/lumen-harbor",
            RepoName = "lumen",
            Branch = "feature/cart",
            Upstream = "origin/feature/cart",
            Remote = "origin",
            UpstreamBranch = "feature/cart",
            Ahead = 3,
            Unpushed = 3,
            Files = [cart, orders],
            Commits = [new GitCommit { Sha = "a41c9e2", Subject = "Split cart total into subtotal and discount", Date = now, Pushed = false }],
            LineCounts = ImmutableDictionary<string, int>.Empty.Add("src/checkout/Cart.tsx", 96).Add("api/orders.ts", 120),
            HeadHasParent = true,
            RecentCoauthors = ["Ada Lovelace <ada@lumen.dev>", "Grace Hopper <grace@lumen.dev>", "Linus <linus@kernel.org>"],
        };
        state.UpdateGit(p => p with { Snapshots = p.Snapshots.SetItem(SampleCwd, snap), Repos = SampleRepos });
        var tab = new GitTab(state);
        return (tab, Theme.Size.TabPaneHeight(Theme.Size.GitCardHeight), _ =>
        {
            // ReadsLocalFiles stays on so the tool shows the snapshot, but nothing reads: no
            // trigger here calls RefreshGit.
            Pump(0.6);
            then(state);
        });
    }

    private static FileChange SampleCartFile() => new()
    {
        Path = "src/checkout/Cart.tsx",
        Added = 24,
        Removed = 6,
        Kind = "edit",
        Patch =
        [
            new DiffLine { Kind = DiffLineKind.Hunk, Text = "@@ -12,7 +12,8 @@" },
            new DiffLine { Kind = DiffLineKind.Context, Text = "  const items = useCart();", OldLine = 12, NewLine = 12 },
            new DiffLine { Kind = DiffLineKind.Removed, Text = "  const total = items.reduce((s, i) => s + i.price, 0);", OldLine = 13 },
            new DiffLine { Kind = DiffLineKind.Removed, Text = "  return <Total value={total} />;", OldLine = 14 },
            new DiffLine { Kind = DiffLineKind.Added, Text = "  const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0);", NewLine = 13 },
            new DiffLine { Kind = DiffLineKind.Added, Text = "  const total = applyDiscount(subtotal, code);", NewLine = 14 },
            new DiffLine { Kind = DiffLineKind.Added, Text = "  return <Total value={total} currency={currency} />;", NewLine = 15 },
            new DiffLine { Kind = DiffLineKind.Context, Text = "}", OldLine = 15, NewLine = 16 },
            new DiffLine { Kind = DiffLineKind.Hunk, Text = "@@ -48,6 +49,24 @@" },
            new DiffLine { Kind = DiffLineKind.Context, Text = "export function CartRow({ item }: Props) {", OldLine = 48, NewLine = 49 },
            new DiffLine { Kind = DiffLineKind.Removed, Text = "\treturn <Row label={item.name} price={item.price} />;", OldLine = 49 },
            .. Enumerable.Range(0, 18).Select(i => new DiffLine
            {
                Kind = DiffLineKind.Added,
                Text = i == 0 ? "\tconst price = formatPrice(item.price * item.qty, currency); // a long line that runs past the pane so it scrolls sideways" : $"\t// discount rule {i + 1}",
                NewLine = 50 + i,
            }),
            new DiffLine { Kind = DiffLineKind.Context, Text = "}", OldLine = 50, NewLine = 68 },
        ],
    };

    // MARK: - Request scenes

    private static PendingRequest PermissionRequest()
    {
        var now = DateTime.UtcNow;
        return new PendingRequest
        {
            Id = "r1",
            Kind = PendingRequestKind.Permission,
            SessionId = "s1",
            Tool = "Edit",
            Title = "Allow Edit?",
            Detail = "src/checkout/Cart.tsx",
            Reason = "Split the cart total so discounts apply before tax.",
            Files = [SampleCartFile()],
            AlwaysRules = ["Edit(src/checkout/**)"],
            ReceivedAt = now.AddSeconds(-12),
            Deadline = now.AddSeconds(46),
        };
    }

    private static PendingRequest BashRequest()
    {
        var now = DateTime.UtcNow;
        return new PendingRequest
        {
            Id = "r2",
            Kind = PendingRequestKind.Permission,
            SessionId = "s1",
            Tool = "Bash",
            Title = "Allow Bash?",
            Detail = "npm run test -- --watch=false --coverage && npx tsc --noEmit -p tsconfig.json && npm run lint -- --max-warnings 0 && echo done && npm run build -- --mode production --sourcemap",
            Reason = "Run the checks before committing.",
            AlwaysRules = ["Bash(npm run test:*)", "Bash(npx tsc:*)", "Bash(npm run lint:*)", "Bash(npm run build:*)"],
            ReceivedAt = now.AddSeconds(-3),
            Deadline = now.AddSeconds(55),
        };
    }

    private static PendingRequest CommitRequest()
    {
        var now = DateTime.UtcNow;
        var cart = SampleCartFile();
        return new PendingRequest
        {
            Id = "r3",
            Kind = PendingRequestKind.Commit,
            SessionId = "s1",
            Tool = "Bash",
            Title = "Split cart total into subtotal and discount",
            Detail = "git commit -m \"Split cart total into subtotal and discount\"",
            Files =
            [
                cart,
                new FileChange { Path = "api/orders.ts", Added = 3, Removed = 1, Kind = "edit", Patch = cart.Patch.Take(8).ToList() },
                new FileChange { Path = "src/checkout/useCart.ts", Added = 9, Removed = 0, Kind = "new" },
            ],
            ReceivedAt = now.AddSeconds(-20),
            Deadline = now.AddSeconds(38),
        };
    }

    private static PendingRequest PlanRequest()
    {
        var now = DateTime.UtcNow;
        var plan = string.Join("\n",
        [
            "# Plan: Split the cart total",
            "",
            "Discounts apply before tax, so the total has to be built in two steps.",
            "",
            "## Steps",
            "",
            "1. Add `subtotal` to `Cart.tsx` and keep `total` for the display.",
            "2. Move the discount rule into `applyDiscount`.",
            "3. Retry failed order requests in `api/orders.ts`.",
            "",
            "## Tests",
            "",
            "- A cart with no code keeps its total.",
            "- A 10% code takes 10% off the subtotal, not the tax.",
            "",
            "```ts",
            "const total = applyDiscount(subtotal, code);",
            "```",
            "",
            "## Risks",
            "",
            "The currency field is optional in old carts.",
        ]);
        return new PendingRequest
        {
            Id = "r4",
            Kind = PendingRequestKind.Plan,
            SessionId = "s1",
            Tool = "ExitPlanMode",
            Title = "Split the cart total",
            Detail = plan,
            ReceivedAt = now.AddSeconds(-30),
            Deadline = now.AddSeconds(268),
        };
    }

    private static AppState RequestState(PendingRequest request)
    {
        var state = NewState();
        var now = DateTime.UtcNow;
        state.Sessions = [new Session { Id = "s1", Cwd = SampleCwd, WorktreeName = "harbor", RepoName = "lumen", State = SessionState.NeedsYou, StartedAt = now, LastEventAt = now, TermProgram = "WindowsTerminal" }];
        state.Pending = [request];
        state.IsCardOpen = true;
        return state;
    }

    private static (FrameworkElement, double, Action<FrameworkElement>?) Request(PendingRequest request, Action<AppState>? then, Action<AppState>? afterShown = null)
    {
        var state = RequestState(request);
        then?.Invoke(state);
        var card = new RequestCardHost(state);
        // The card's height below the strip, minus what the strip row, footer and padding take.
        double height = state.CardHeight - Theme.Size.BridgeHeight - 2 * Theme.Size.SpaceM - Theme.Size.SidePadding - 2 * Theme.Size.WellPadding;
        return (card, height, afterShown is null ? null : _ => { Pump(0.6); afterShown(state); });
    }

    /// A plan past `planMaxLines`: the card cuts it with "… N more lines · open in the terminal".
    private static PendingRequest LongPlanRequest()
    {
        var plan = PlanRequest();
        var lines = new List<string> { "# Plan: A long migration", "" };
        for (int i = 1; lines.Count <= Theme.Limits.PlanMaxLines + 40; i++)
        {
            lines.Add($"## Step {i}");
            lines.Add("");
            lines.Add($"Move `module{i}` to the new API and keep its old entry point for one release.");
            lines.Add("");
        }
        return plan with { Id = "r5", Title = "A long migration", Detail = string.Join("\n", lines) };
    }

    private static (FrameworkElement, double, Action<FrameworkElement>?) Question()
    {
        var state = NewState();
        var now = DateTime.UtcNow;
        state.Sessions = [new Session { Id = "s1", Cwd = SampleCwd, WorktreeName = "harbor", State = SessionState.NeedsYou, StartedAt = now, LastEventAt = now }];
        state.Question = new QuestionPreview
        {
            SessionId = "s1",
            Question = "Which cart should the discount apply to: the saved cart or the live one?",
            Options = ["The saved cart", "The live cart", "Both, live first", "Ask me later"],
        };
        state.QuestionShown = true;
        state.IsCardOpen = true;
        var card = new RequestCardHost(state);
        double height = Theme.Size.QuestionCardHeight - Theme.Size.BridgeHeight - 2 * Theme.Size.SpaceM - Theme.Size.SidePadding - 2 * Theme.Size.WellPadding;
        return (card, height, null);
    }

    private static (FrameworkElement, double, Action<FrameworkElement>?) Actions()
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
        foreach (var request in new[] { PermissionRequest(), CommitRequest(), PlanRequest() })
        {
            var state = RequestState(request);
            stack.Children.Add(new RequestActionStrip(state, request) { Margin = new Thickness(0, 0, 0, 10), HorizontalAlignment = HorizontalAlignment.Right });
            stack.Children.Add(new RequestActionStrip(state, request, allKeys: true) { Margin = new Thickness(0, 0, 0, 16), HorizontalAlignment = HorizontalAlignment.Right });
        }
        return (stack, 220, null);
    }

    // MARK: - Settings

    private static (FrameworkElement, double, Action<FrameworkElement>?) Settings(double scroll, bool welcome = false, HooksInstallerStatus? status = null)
    {
        SettingsPage.StatusPreview = status;
        var state = NewState();
        state.SelectedTab = CardTab.Settings;
        state.IsCardOpen = true;
        // The Welcome page without its marker file: nothing on disk is touched.
        Welcome.ShowForPreview(welcome);
        var page = new SettingsPage(state);
        Welcome.ShowForPreview(false);
        double height = Theme.Size.SettingsCardHeight - Theme.Size.BridgeHeight - 2 * Theme.Size.SpaceM - Theme.Size.CardFooterHeight - Theme.Size.SidePadding - 2 * Theme.Size.WellPadding;
        return (page, height, element =>
        {
            Pump(0.3);
            SettingsPage.StatusPreview = null;
            if (scroll > 0) ((SettingsPage)element).ScrollTo(scroll);
        });
    }
}
