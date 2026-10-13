// RequestCardsTests.cs
// Wave 1d's panes: the request cards' words (RequestActions), the Settings captions, and the
// harness (Features/PanesHarnessB.cs), which renders the Git tool, the request cards and
// Settings to PNGs when NOTCHCODE_PANES_B_OUT names a folder (NOTCHCODE_PANES_B_REPO the
// checkout the live Git scenes read, read-only); otherwise it does nothing, so the normal
// test run never opens a window.

using Notchcode.Core;
using Notchcode.Features;
using Notchcode.Features.Requests;
using Notchcode.Features.Settings;
using Notchcode.State;

namespace Notchcode.Tests;

public class RequestCardsTests
{
    [Fact]
    public void RendersPanesBWhenAsked()
    {
        var dir = Environment.GetEnvironmentVariable("NOTCHCODE_PANES_B_OUT");
        if (string.IsNullOrEmpty(dir)) return;
        var repo = Environment.GetEnvironmentVariable("NOTCHCODE_PANES_B_REPO") ?? Environment.CurrentDirectory;
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try { PanesHarnessB.Run(dir, repo); }
            catch (Exception e) { error = e; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (error is not null) throw new Exception("harness failed", error);
    }

    private static PendingRequest Request(PendingRequestKind kind, string tool = "Bash", string title = "t", string detail = "d") => new()
    {
        Id = "r",
        Kind = kind,
        SessionId = "s",
        Tool = tool,
        Title = title,
        Detail = detail,
        ReceivedAt = DateTime.UtcNow,
        Deadline = DateTime.UtcNow.AddSeconds(58),
    };

    [Fact]
    public void EachKindOffersItsThreeActions()
    {
        var permission = PendingRequestKind.Permission.Actions;
        Assert.Equal(("Deny", "Always", "Allow"), (permission.Deny.Title, permission.Middle.Title, permission.Allow.Title));
        var commit = PendingRequestKind.Commit.Actions;
        Assert.Equal(("Skip", "Edit", "Commit"), (commit.Deny.Title, commit.Middle.Title, commit.Allow.Title));
        var plan = PendingRequestKind.Plan.Actions;
        Assert.Equal(("Revise", "Auto-accept", "Approve"), (plan.Deny.Title, plan.Middle.Title, plan.Allow.Title));
    }

    [Fact]
    public void HeadlinesAndSummaries()
    {
        Assert.Equal("Allow Bash?", Request(PendingRequestKind.Permission).Headline);
        Assert.Equal("Commit?", Request(PendingRequestKind.Commit).Headline);
        Assert.Equal("Plan ready", Request(PendingRequestKind.Plan).Headline);
        // A plan with no body has no summary; one with a body shows its heading.
        Assert.Equal("", Request(PendingRequestKind.Plan, title: "Plan ready", detail: "").Summary);
        Assert.Equal("Split", Request(PendingRequestKind.Plan, title: "Split", detail: "# Split\nbody").Summary);
        Assert.Equal("subject", Request(PendingRequestKind.Commit, title: "subject").Summary);
    }

    [Fact]
    public void TimeLeftNeverGoesBelowZero()
    {
        var r = Request(PendingRequestKind.Permission);
        Assert.Equal(0, r.Remaining(r.Deadline.AddSeconds(5)));
        Assert.Equal(1, r.RemainingFraction(r.ReceivedAt), 3);
        Assert.Equal(0, r.RemainingFraction(r.Deadline));
    }

    [Fact]
    public void ArrowsScrollAPlanAndNeverAnswerIt()
    {
        var state = new AppState(new Preferences(), savesPrefs: false);
        var plan = Request(PendingRequestKind.Plan, tool: "ExitPlanMode", title: "Split", detail: "# Split\n\nbody");
        state.Pending = [plan];
        state.OpenCard();
        Assert.True(state.HandleKey(NotchKey.Down));
        Assert.True(state.HandleKey(NotchKey.Down));
        Assert.True(state.HandleKey(NotchKey.Up));
        Assert.Single(state.Pending);
        Assert.Equal(3, state.RequestDiffScroll.Seq);
        Assert.Equal(-Notchcode.UI.Theme.Limits.PlanScrollBlocks, state.RequestDiffScroll.Delta);
    }

    [Fact]
    public void AboutShowsAVersion()
    {
        Assert.Matches(@"^\d+\.\d+\.\d+", SettingsPage.Version);
        Assert.NotEqual("1.0.0", SettingsPage.Version);
        Assert.Contains("the newest 5 kept", SettingsPage.BackupCaption);
    }

    [Fact]
    public void HotkeyLabelNamesTheLiveChord()
    {
        Assert.StartsWith("Ctrl ", SettingsPage.HotkeyLabel("ctrl-alt-space"));
        Assert.DoesNotContain("Ctrl", SettingsPage.HotkeyLabel("alt-space"));
    }
}
