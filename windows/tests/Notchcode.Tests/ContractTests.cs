// ContractTests.cs
// The envelope round trip: what the hook writes, the app reads back unchanged.

using Notchcode.Core;

namespace Notchcode.Tests;

public class ContractTests
{
    [Fact]
    public void HookEnvelopeRoundTripsThroughJson()
    {
        const string line = """
            {"v":1,"kind":"pre_tool","id":"abc","session_id":"s1","cwd":"C:\\x","ts":1760000000.5,"pid":42,
             "payload":{"tool_name":"Bash","z":1,"a":[true,null,"t"],"tool_input":{"command":"git commit -m hi"}},
             "tree":{"root":"C:/x","head":"","status_b64":"IE0gYS50eHQKPz8gYi50eHQ=","diff_b64":"ZGlmZg==","truncated":true}}
            """;
        var env = HookEnvelope.FromLine(line.Replace("\r", "").Replace("\n", ""));
        Assert.NotNull(env);
        Assert.Equal(EventKind.PreTool, env!.Kind);
        Assert.True(env.IsBlocking);
        Assert.Equal("s1", env.ResolvedSessionId);
        Assert.Equal("Bash", env.Payload["tool_name"]?.StringValue);
        Assert.Null(env.Tree!.Head);
        Assert.Equal([" M a.txt", "?? b.txt"], env.Tree.Status);
        Assert.Equal("diff", env.Tree.Diff);

        var again = HookEnvelope.FromLine(env.ToLine());
        Assert.NotNull(again);
        Assert.Equal(env, again);
        // Payload key order survives.
        Assert.Equal(["tool_name", "z", "a", "tool_input"], again!.Payload.ObjectValue!.Select(kv => kv.Key));
        Assert.Equal("pre_tool", EventKind.PreTool.RawValue());
    }

    [Fact]
    public void ReplyLineMatchesSwiftEncoding()
    {
        var payload = JsonValue.Parse("""{"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}""");
        var line = HookReply.ReplyLine(new HookReply { Decision = Decision.Allow, Always = true }, "id/1", payload);
        Assert.Equal("""{"always":true,"decision":"allow","id":"id/1","updated_permissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"npm test:*","toolName":"Bash"}],"type":"addRules"}]}""" + "\n", line);
        Assert.Equal("""{"always":false,"decision":"none","id":"x"}""" + "\n", HookReply.ReplyLine(null, "x", JsonValue.Null));
    }

    [Fact]
    public void PreferencesTakeDefaultsForMissingKeys()
    {
        var path = Path.Combine(Path.GetTempPath(), "notchcode-test-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(path, """{"idleStyle":"closed","peekSeconds":6}""");
            var prefs = PreferencesStore.Load(path);
            Assert.Equal(IdleStyle.Closed, prefs.IdleStyle);
            Assert.Equal(6, prefs.PeekSeconds);
            Assert.True(prefs.KeycapsBesideButtons);
            PreferencesStore.Save(prefs with { AttentionStyle = AttentionStyle.Wings }, path);
            var text = File.ReadAllText(path);
            Assert.StartsWith("{\"attentionStyle\":\"wings\",\"filesTreeHidden\":false", text);
            Assert.Equal(AttentionStyle.Wings, PreferencesStore.Load(path).AttentionStyle);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void ProjectFolderNameReplacesNonAlphanumerics()
        => Assert.Equal("C--Users-evanc-Desktop-Personal-Projects-notchcode",
                        NotchcodePaths.ProjectFolderName(@"C:\Users\evanc\Desktop\Personal Projects\notchcode"));
}
