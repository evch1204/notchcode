// AppStateTests.cs
// The notch's mode and the session ordering from AppState's derived values.

using Notchcode.Core;
using Notchcode.State;

namespace Notchcode.Tests;

public class AppStateTests
{
    private static Session MakeSession(string id, SessionState state, string cwd, string? repo = null, double ageSeconds = 0)
    {
        var at = DateTime.UtcNow.AddSeconds(-ageSeconds);
        return new Session { Id = id, Cwd = cwd, WorktreeName = Format.FileName(cwd), RepoName = repo, State = state, StartedAt = at, LastEventAt = at };
    }

    [Fact]
    public void ModeFollowsSessionsAndRequests()
    {
        var state = new AppState(new Preferences(), savesPrefs: false);
        state.Refresh();
        Assert.Equal(NotchMode.Closed, state.Mode);

        state.Sessions = [MakeSession("a", SessionState.Done, @"C:\r\a")];
        state.Refresh();
        Assert.Equal(NotchMode.Resting, state.Mode);

        state.Sessions = state.Sessions.Add(MakeSession("b", SessionState.Working, @"C:\r\b", ageSeconds: 5));
        state.Refresh();
        Assert.Equal(NotchMode.Wings, state.Mode);

        state.Pending = [new PendingRequest { Id = "r1", SessionId = "a", Tool = "Bash" }];
        state.Refresh();
        Assert.Equal(NotchMode.Attention, state.Mode);
        Assert.Equal("a", state.PrimarySession?.Id);
        Assert.True(state.AnswerKeysAllowedAt > DateTime.UtcNow);
        Assert.IsType<CardContent.Request>(state.CardContent);
    }

    [Fact]
    public void GroupsPutTheMostUrgentFirst()
    {
        var state = new AppState(new Preferences(), savesPrefs: false)
        {
            Sessions =
            [
                MakeSession("idle", SessionState.Idle, @"C:\x\one"),
                MakeSession("w1", SessionState.Working, @"C:\r\main", repo: "r", ageSeconds: 10),
                MakeSession("w2", SessionState.Working, @"C:\r\wt", repo: "r"),
            ],
        };
        var groups = state.SessionGroups;
        Assert.Equal(["repo|r", @"dir|C:\x\one"], groups.Select(g => g.Id));
        Assert.Equal(["w2", "w1", "idle"], state.OrderedSessions.Select(s => s.Id));
        Assert.True(groups[0].HasWorktrees);
    }
}
