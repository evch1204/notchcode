// HooksInstallerTests.cs
// Connect / Disconnect on copies of a settings.json shaped like this PC's: Orca hooks with
// `"shell": "powershell"` and -EncodedCommand, a BurntToast Stop hook, a status line of its
// own. Never the owner's real file: every test works in a temp folder.

using System.Text;
using Notchcode.ClaudeCode;

namespace Notchcode.Tests;

public sealed class HooksInstallerTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("nc-hooks-").FullName;
    private readonly HookInstallPaths _paths;

    public HooksInstallerTests()
    {
        _paths = new HookInstallPaths(
            Path.Combine(_dir, ".claude", "settings.json"),
            Path.Combine(_dir, "notchcode", "statusline-chain.json"),
            Path.Combine(_dir, "notchcode", "bin"));
        Directory.CreateDirectory(Path.GetDirectoryName(_paths.SettingsFile)!);
        Directory.CreateDirectory(_paths.BinDirectory);
        File.WriteAllBytes(_paths.HookExecutable, [0x4D, 0x5A]); // a stand-in exe; InstallScripts may refresh it
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch (IOException) { }
    }

    /// The shape of the owner's file: Orca's PowerShell hooks, BurntToast, a status line, a
    /// unicode escape and an exponent that must come back exactly as written.
    private const string OrcaFixture = """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "permissions": {
            "allow": [
              "Bash(npm test:*)",
              "Read(C:\\Users\\me\\**)"
            ],
            "defaultMode": "acceptEdits"
          },
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "shell": "powershell",
                    "command": "powershell -NoProfile -NonInteractive -EncodedCommand JABlAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQAgAD0AIAAnAFMAdABvAHAAJwA=",
                    "timeout": 10
                  }
                ]
              }
            ],
            "PostToolUse": [
              {
                "matcher": "Edit|Write",
                "hooks": [
                  {
                    "type": "command",
                    "shell": "powershell",
                    "command": "powershell -NoProfile -EncodedCommand SQBuAHYAbwBrAGUALQBPAHIAYwBhAA==",
                    "async": true
                  }
                ]
              }
            ],
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "powershell -NoProfile -Command \"Import-Module BurntToast; New-BurntToastNotification -Text 'Claude Code', 'Done \u2713'\""
                  }
                ]
              }
            ]
          },
          "statusLine": {
            "type": "command",
            "shell": "powershell",
            "command": "powershell -NoProfile -EncodedCommand JABpAG4AcAB1AHQA",
            "padding": 0
          },
          "cleanupPeriodDays": 1.5e2,
          "model": "opus"
        }

        """;

    private void WriteSettings(string text, bool crlf = false, bool bom = false)
    {
        text = text.Replace("\r\n", "\n");
        if (crlf) text = text.Replace("\n", "\r\n");
        var bytes = new UTF8Encoding(bom).GetPreamble().Concat(new UTF8Encoding(false).GetBytes(text)).ToArray();
        File.WriteAllBytes(_paths.SettingsFile, bytes);
    }

    private byte[] Bytes() => File.ReadAllBytes(_paths.SettingsFile);

    private OJ Root() => OJParser.Parse(Bytes());

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void ConnectThenDisconnectGivesBackTheSameBytes(bool crlf, bool bom)
    {
        WriteSettings(OrcaFixture, crlf, bom);
        var before = Bytes();

        HooksInstaller.Connect(_paths, shell: "powershell");
        Assert.NotEqual(before, Bytes());
        Assert.Equal(HooksInstallerStatus.Connected, HooksInstaller.Status(_paths));

        HooksInstaller.Disconnect(_paths);
        Assert.Equal(before, Bytes());
        Assert.Equal(HooksInstallerStatus.NotConnected, HooksInstaller.Status(_paths));
        Assert.False(File.Exists(_paths.ChainFile));
    }

    [Fact]
    public void ConnectLeavesEveryOtherEntryAlone()
    {
        WriteSettings(OrcaFixture);
        var before = Root();
        HooksInstaller.Connect(_paths, shell: "bash");
        var after = Root();

        // Theirs, untouched and first in their event lists.
        foreach (var evt in new[] { "SessionStart", "PostToolUse", "Stop" })
            Assert.Equal(before["hooks"]![evt]!.Items![0].Canonical, after["hooks"]![evt]!.Items![0].Canonical);
        Assert.Equal(before["permissions"]!.Canonical, after["permissions"]!.Canonical);
        var text = Encoding.UTF8.GetString(Bytes());
        Assert.Contains("\"cleanupPeriodDays\": 1.5e2", text);
        Assert.Contains("'Done \\u2713'", text);
        Assert.Contains("\"Read(C:\\\\Users\\\\me\\\\**)\"", text);

        // Ours: the exec form, forward slashes, the table's timeouts.
        var exe = _paths.HookExecutable.Replace('\\', '/');
        var permission = after["hooks"]!["PermissionRequest"]!.Items![0]["hooks"]!.Items![0];
        Assert.Equal(exe, permission["command"]!.StringValue);
        Assert.Equal("permission", permission["args"]!.Items![0].StringValue);
        Assert.Equal("305", permission["timeout"]!.NumberLiteral);
        Assert.Null(permission["async"]);
        var preTool = after["hooks"]!["PreToolUse"]!.Items![0];
        Assert.Equal("Bash", preTool["matcher"]!.StringValue);
        Assert.Equal("Bash(git commit *)", preTool["hooks"]!.Items![0]["if"]!.StringValue);
        Assert.Equal("65", preTool["hooks"]!.Items![0]["timeout"]!.NumberLiteral);
        var post = after["hooks"]!["PostToolUse"]!.Items!;
        Assert.Equal(2, post.Count);
        Assert.Equal("Edit|Write|MultiEdit|Bash", post[1]["matcher"]!.StringValue);
        var start = after["hooks"]!["SessionStart"]!.Items![1]["hooks"]!.Items!;
        Assert.Equal(["launch", "session_start"], start.Select(h => h["args"]!.Items![0].StringValue));
        Assert.All(start, h => Assert.Equal(true, h["async"]!.BoolValue));

        // The status line: ours, padding carried, the old one saved with its shell.
        var line = after["statusLine"]!;
        Assert.Equal(exe + " statusline", line["command"]!.StringValue);
        Assert.Equal("0", line["padding"]!.NumberLiteral);
        var chain = OJParser.Parse(File.ReadAllBytes(_paths.ChainFile));
        Assert.Equal(before["statusLine"]!.Canonical, chain["previous"]!.Canonical);
        // The old status line names its shell ("powershell"); that wins over the PC's default.
        Assert.Equal("powershell", chain["shell"]!.StringValue);

        // A second connect changes nothing and makes no backup.
        var bytes = Bytes();
        int backups = Backups().Length;
        HooksInstaller.Connect(_paths, shell: "bash");
        Assert.Equal(bytes, Bytes());
        Assert.Equal(backups, Backups().Length);
    }

    private string[] Backups()
        => Directory.GetFiles(Path.GetDirectoryName(_paths.SettingsFile)!, "settings.json.notchcode-backup-*");

    [Fact]
    public void ConnectOnNoFileCreatesOneAndDisconnectEmptiesIt()
    {
        HooksInstaller.Connect(_paths, shell: "powershell");
        Assert.Equal(HooksInstallerStatus.Connected, HooksInstaller.Status(_paths));
        Assert.Empty(Backups());
        Assert.False(File.Exists(_paths.ChainFile));
        HooksInstaller.Disconnect(_paths);
        var root = Root();
        Assert.Null(root["statusLine"]);
        Assert.Null(root["hooks"]);   // emptied by taking ours out: the key goes too
        Assert.Equal("{}\n", File.ReadAllText(_paths.SettingsFile));
    }

    [Fact]
    public void StaleWhenTheTimeoutIsOldTheExeIsGoneOrTheFormIsAString()
    {
        WriteSettings(OrcaFixture);
        HooksInstaller.Connect(_paths, shell: "powershell");
        var text = Encoding.UTF8.GetString(Bytes());

        File.WriteAllText(_paths.SettingsFile, text.Replace("\"timeout\": 305", "\"timeout\": 65"));
        Assert.Equal(HooksInstallerStatus.Stale, HooksInstaller.Status(_paths));

        File.WriteAllText(_paths.SettingsFile, text);
        Assert.Equal(HooksInstallerStatus.Connected, HooksInstaller.Status(_paths));
        File.Move(_paths.HookExecutable, _paths.HookExecutable + ".gone");
        Assert.Equal(HooksInstallerStatus.Stale, HooksInstaller.Status(_paths));
        File.Move(_paths.HookExecutable + ".gone", _paths.HookExecutable);

        // Pointing outside the bin folder (an older install).
        File.WriteAllText(_paths.SettingsFile, text.Replace(_paths.BinDirectory.Replace('\\', '/'), "C:/elsewhere/bin"));
        Assert.Equal(HooksInstallerStatus.Stale, HooksInstaller.Status(_paths));

        // Reconnect fixes it, and still leaves Orca alone.
        HooksInstaller.Connect(_paths, shell: "powershell");
        Assert.Equal(HooksInstallerStatus.Connected, HooksInstaller.Status(_paths));
        Assert.Contains("-EncodedCommand JABlAHIA", Encoding.UTF8.GetString(Bytes()));
    }

    [Fact]
    public void PartialWhenSomeOfOursAreMissing()
    {
        WriteSettings(OrcaFixture);
        HooksInstaller.Connect(_paths, shell: "powershell");
        var root = Root();
        var hooks = root["hooks"]!.Members!.Where(m => m.Key != "SubagentStop").ToList();
        var top = root.Members!.Select(m => m.Key == "hooks" ? m with { Value = OJ.Object(hooks) } : m);
        File.WriteAllText(_paths.SettingsFile, OJ.Object(top).Pretty() + "\n");
        Assert.Equal(HooksInstallerStatus.Partial, HooksInstaller.Status(_paths));
    }

    [Fact]
    public void BackupsKeepTheNewestFive()
    {
        WriteSettings(OrcaFixture);
        for (int i = 0; i < 4; i++)
        {
            HooksInstaller.Connect(_paths, shell: "powershell");
            HooksInstaller.Disconnect(_paths);
            Thread.Sleep(5); // distinct millisecond stamps
        }
        Assert.Equal(HooksInstaller.KeptBackups, Backups().Length);
    }

    [Fact]
    public void InvalidJsonIsNeverTouched()
    {
        File.WriteAllText(_paths.SettingsFile, "{ \"hooks\": [ }");
        var ex = Assert.Throws<HooksInstallerException>(() => HooksInstaller.Connect(_paths, shell: "bash"));
        Assert.StartsWith("settings.json is not valid JSON", ex.Message);
        Assert.Equal("{ \"hooks\": [ }", File.ReadAllText(_paths.SettingsFile));
    }

    // MARK: Wave 3d

    [Fact]
    public void MalformedFilesAreRefusedByEveryWriteAndStatusSaysNotConnected()
    {
        foreach (var text in new[] { "{ \"hooks\": [ }", "[1, 2]", "{\"hooks\": [1]}", "{\"hooks\": {}} trailing" })
        {
            File.WriteAllText(_paths.SettingsFile, text);
            Assert.Throws<HooksInstallerException>(() => HooksInstaller.Connect(_paths, shell: "bash"));
            Assert.Equal(text, File.ReadAllText(_paths.SettingsFile));
            Assert.Equal(HooksInstallerStatus.NotConnected, HooksInstaller.Status(_paths));
        }
        File.WriteAllText(_paths.SettingsFile, "[1]");
        Assert.Throws<HooksInstallerException>(() => HooksInstaller.Disconnect(_paths));
        Assert.Equal("[1]", File.ReadAllText(_paths.SettingsFile));
        Assert.Empty(Backups());
    }

    [Fact]
    public void AStringFormEntryOfOursIsStale()
    {
        WriteSettings(OrcaFixture);
        HooksInstaller.Connect(_paths, shell: "powershell");
        var root = Root();
        // The Stop entry in the string form, as a hand edit or an older build would write it.
        var exe = _paths.HookCommandPath;
        var stringForm = OJ.Object([new OJMember("type", OJ.String("command")), new OJMember("command", OJ.String(exe + " stop")),
                                    new OJMember("timeout", OJ.Number("5")), new OJMember("async", OJ.Bool(true))]);
        var hooks = root["hooks"]!.Members!.Select(m => m.Key != "Stop" ? m : m with
        {
            Value = OJ.Array(m.Value.Items!.Select(g => g["hooks"]!.Items!.Any(h => h["command"]?.StringValue == exe)
                ? OJ.Object([new OJMember("hooks", OJ.Array([stringForm]))]) : g)),
        });
        File.WriteAllText(_paths.SettingsFile, OJ.Object(root.Members!.Select(m => m.Key == "hooks" ? m with { Value = OJ.Object(hooks) } : m)).Pretty() + "\n");
        Assert.Equal(HooksInstallerStatus.Stale, HooksInstaller.Status(_paths));
        HooksInstaller.Connect(_paths, shell: "powershell");
        Assert.Equal(HooksInstallerStatus.Connected, HooksInstaller.Status(_paths));
        // Reconnect replaced ours and only ours: BurntToast is still first.
        Assert.Contains("BurntToast", Root()["hooks"]!["Stop"]!.Items![0].Canonical);
        Assert.Equal(2, Root()["hooks"]!["Stop"]!.Items!.Count);
    }

    [Fact]
    public void TheChainKeepsTheOldStatusLineAndItsShell()
    {
        const string plain = "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \"node \\\"C:/Users/me/sidecar/statusline.mjs\\\"\"\n  }\n}\n";
        WriteSettings(plain);
        HooksInstaller.Connect(_paths, shell: "bash");
        var chain = OJParser.Parse(File.ReadAllBytes(_paths.ChainFile));
        Assert.Equal("node \"C:/Users/me/sidecar/statusline.mjs\"", chain["previous"]!["command"]!.StringValue);
        Assert.Equal("bash", chain["shell"]!.StringValue);   // no shell of its own: the PC's
        HooksInstaller.Disconnect(_paths);
        Assert.Equal(plain, File.ReadAllText(_paths.SettingsFile));
        Assert.False(File.Exists(_paths.ChainFile));

        // An unreadable chain file: Disconnect refuses rather than guess the old status line.
        HooksInstaller.Connect(_paths, shell: "bash");
        var connected = Bytes();
        File.WriteAllText(_paths.ChainFile, "{ not json");
        Assert.Throws<HooksInstallerException>(() => HooksInstaller.Disconnect(_paths));
        Assert.Equal(connected, Bytes());
    }

    [Fact]
    public void ASymlinkedSettingsFileStaysALink()
    {
        var real = Path.Combine(_dir, "dotfiles", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(real)!);
        File.WriteAllText(real, OrcaFixture.Replace("\r\n", "\n"));
        try { File.CreateSymbolicLink(_paths.SettingsFile, real); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // no symlink rights (Developer Mode off)
        var before = File.ReadAllBytes(real);

        HooksInstaller.Connect(_paths, shell: "powershell");
        Assert.NotNull(new FileInfo(_paths.SettingsFile).LinkTarget);
        Assert.Contains("notchcode-hook", File.ReadAllText(real));
        // The backup holds the content, not a link.
        var backup = Assert.Single(Backups());
        Assert.Null(new FileInfo(backup).LinkTarget);
        Assert.Equal(before, File.ReadAllBytes(backup));

        HooksInstaller.Disconnect(_paths);
        Assert.NotNull(new FileInfo(_paths.SettingsFile).LinkTarget);
        Assert.Equal(before, File.ReadAllBytes(real));
    }

    [Fact]
    public void CommandLineFlagsReturnExitCodes()
    {
        Assert.Null(HooksInstaller.HandleCommandLine(["--demo"], _paths));
        WriteSettings(OrcaFixture);
        var before = Bytes();
        Assert.Equal(1, HooksInstaller.HandleCommandLine(["--hooks-status"], _paths));            // not connected
        Assert.Equal(0, HooksInstaller.HandleCommandLine(["--CONNECT"], _paths));
        Assert.Equal(0, HooksInstaller.HandleCommandLine(["--hooks-status"], _paths));            // connected
        File.Delete(_paths.HookExecutable);
        Assert.Equal(3, HooksInstaller.HandleCommandLine(["--hooks-status"], _paths));            // stale
        File.WriteAllBytes(_paths.HookExecutable, [0x4D, 0x5A]);
        Assert.Equal(0, HooksInstaller.HandleCommandLine(["--disconnect"], _paths));
        Assert.Equal(before, Bytes());
        File.WriteAllText(_paths.SettingsFile, "{ broken");
        Assert.Equal(1, HooksInstaller.HandleCommandLine(["--connect"], _paths));
        Assert.Equal("{ broken", File.ReadAllText(_paths.SettingsFile));
        Assert.Equal(["connected", "not-connected", "partial", "stale"],
                     new[] { HooksInstallerStatus.Connected, HooksInstallerStatus.NotConnected, HooksInstallerStatus.Partial, HooksInstallerStatus.Stale }
                         .Select(HooksInstaller.StatusWord));
    }

    [Fact]
    public void StatusLineCommandQuotesOnlyWhenItMust()
    {
        Assert.Equal("C:/Users/me/AppData/Local/notchcode/bin/notchcode-hook.exe statusline",
                     HooksInstaller.StatusLineCommand("C:/Users/me/AppData/Local/notchcode/bin/notchcode-hook.exe", "bash"));
        Assert.Equal("'C:/Users/John Doe/x/notchcode-hook.exe' statusline",
                     HooksInstaller.StatusLineCommand("C:/Users/John Doe/x/notchcode-hook.exe", "bash"));
        Assert.Equal("& 'C:/Users/John Doe/x/notchcode-hook.exe' statusline",
                     HooksInstaller.StatusLineCommand("C:/Users/John Doe/x/notchcode-hook.exe", "powershell"));
    }

    [Fact]
    public void OrderedJsonPrintsLikeJsonStringify()
    {
        var oj = OJParser.Parse("{\"a\":[],\"b\":{},\"c\":[1,{\"d\":\"\\u00e9\\/\"}]}");
        Assert.Equal("{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    {\n      \"d\": \"\\u00e9\\/\"\n    }\n  ]\n}", oj.Pretty());
        Assert.Equal("é/", oj["c"]!.Items![1]["d"]!.StringValue);
        Assert.Equal("\"\\u0001\\n\"", OJ.Quote("\u0001\n"));
    }
}
