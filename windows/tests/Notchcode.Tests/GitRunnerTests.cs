// GitRunnerTests.cs
// The Git tool's writes, pinned argument by argument (PLAN.md, "Git tool": full refs on push,
// `--` before every remote and path, pull fast-forward only), and the environment and
// prefix every git run gets (no prompt of any kind, literal pathspecs). Plus the error lines
// a failed write shows. Nothing here runs git.

using Notchcode.Core;
using Notchcode.Features.Git;

namespace Notchcode.Tests;

public class GitRunnerTests
{
    [Fact]
    public void PushNamesFullRefsAfterTheSeparator()
    {
        Assert.Equal(["push", "--", "origin", "refs/heads/seadevil:refs/heads/seadevil"],
            GitCommands.Push("origin", "seadevil", "seadevil"));
        // The upstream branch may differ from the local name.
        Assert.Equal(["push", "--", "upstream", "refs/heads/feature/x:refs/heads/main"],
            GitCommands.Push("upstream", "feature/x", "main"));
    }

    [Fact]
    public void PublishSetsTheUpstreamWithFullRefs()
    {
        Assert.Equal(["push", "-u", "--", "origin", "refs/heads/design/toolbar:refs/heads/design/toolbar"],
            GitCommands.Publish("origin", "design/toolbar"));
    }

    [Fact]
    public void PullIsFastForwardOnly()
    {
        Assert.Equal(["pull", "--ff-only", "--no-rebase", "--", "origin", "main"], GitCommands.Pull("origin", "main"));
    }

    [Fact]
    public void FetchPrunesOneRemote()
    {
        Assert.Equal(["fetch", "--prune", "--", "origin"], GitCommands.Fetch("origin"));
        // A remote that looks like an option still comes after `--`.
        Assert.Equal(["fetch", "--prune", "--", "--upload-pack=evil"], GitCommands.Fetch("--upload-pack=evil"));
    }

    [Fact]
    public void ResetIsTheMixedUndo()
    {
        Assert.Equal(["reset", "--quiet", "HEAD~1"], GitCommands.Reset());
    }

    [Fact]
    public void AddTakesPathsAfterTheSeparator()
    {
        Assert.Equal(["add", "--", "-rf", "app/[id]/page.tsx"], GitCommands.Add(["-rf", "app/[id]/page.tsx"]));
    }

    [Fact]
    public void CommitCarriesOnlyTheGivenParagraphsAndPaths()
    {
        Assert.Equal(["commit", "--only", "--quiet", "-m", "Fix the pill", "--", "a.cs", "b.cs"],
            GitCommands.Commit("Fix the pill", "", "", ["a.cs", "b.cs"]));
        Assert.Equal(["commit", "--only", "--quiet", "-m", "--amend", "-m", "Body", "-m",
                "Co-authored-by: Ada <ada@x.dev>", "--", "new name.cs", "old name.cs"],
            GitCommands.Commit("--amend", "Body", "Co-authored-by: Ada <ada@x.dev>", ["new name.cs", "old name.cs"]));
    }

    [Fact]
    public void EveryRunGetsThePrefixAndTheQuietEnvironment()
    {
        Assert.Equal(["-C", @"C:\repo", "-c", "core.quotePath=false", "status"], GitRunner.Arguments(["status"], @"C:\repo"));
        var env = GitRunner.GitEnvironment;
        Assert.Equal("0", env["GIT_TERMINAL_PROMPT"]);
        Assert.Equal("Never", env["GCM_INTERACTIVE"]);
        Assert.Equal("1", env["GIT_LITERAL_PATHSPECS"]);
        Assert.Equal("0", env["GIT_OPTIONAL_LOCKS"]);
        Assert.Equal("", env["GIT_ASKPASS"]);
        Assert.Equal("C", env["LC_ALL"]);
    }

    [Fact]
    public void GitIsFoundOnlyAtAnAbsolutePath()
    {
        Assert.True(Path.IsPathFullyQualified(GitRunner.GitExecutable));
        Assert.EndsWith("git.exe", GitRunner.GitExecutable, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ErrorLinesSayWhatToDo()
    {
        var timeout = new ProcessRunner.Result(-1, "", "", TimedOut: true);
        Assert.Equal("git push took too long · push from the terminal", GitRunner.ErrorLine(timeout, "origin", GitOp.Push));

        var credentials = new ProcessRunner.Result(128, "", "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n");
        Assert.Equal("No credentials for origin here · push from the terminal", GitRunner.ErrorLine(credentials, "origin", GitOp.Push));

        var diverged = new ProcessRunner.Result(128, "", "hint: Diverging branches\nfatal: Not possible to fast-forward, aborting.\n");
        Assert.Equal("Pull needs a merge · pull from the terminal", GitRunner.ErrorLine(diverged, "origin", GitOp.Pull));

        var identity = new ProcessRunner.Result(128, "", "*** Please tell me who you are.\n");
        Assert.Equal("No git identity · set user.name and user.email in the terminal", GitRunner.ErrorLine(identity, "", GitOp.Commit));

        var rejected = new ProcessRunner.Result(1, "", "To github.com:x/y.git\n ! [rejected]        main -> main (fetch first)\n");
        Assert.Equal("! [rejected]        main -> main (fetch first)", GitRunner.ErrorLine(rejected, "origin", GitOp.Push));
    }
}
