// PipeTests.cs
// The pipe server with a client on another thread: a passive ack, a blocking reply, the
// deadline's "none", a hook that leaves early, a second server on the same name.

using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;
using Notchcode.Core;
using Notchcode.Transport;

namespace Notchcode.Tests;

public sealed class PipeTests : IDisposable
{
    private readonly string _name = "notchcode-test-" + Guid.NewGuid().ToString("N");
    private readonly RecordingSink _sink = new();
    private readonly PipeServer _server;

    public PipeTests()
    {
        _server = new PipeServer(_sink, _name, replyDeadline: plan => plan ? 3 : 1);
        _server.Start();
    }

    public void Dispose() => _server.Stop();

    internal sealed class RecordingSink : IHookEventSink
    {
        public readonly BlockingCollection<(HookEnvelope Envelope, ReplyHandler Reply)> Received = new();
        public readonly BlockingCollection<string> Cancelled = new();
        public readonly BlockingCollection<string> TimedOutIds = new();
        public void Receive(HookEnvelope envelope, ReplyHandler reply) => Received.Add((envelope, reply));
        public void Cancel(string requestId) => Cancelled.Add(requestId);
        public void TimedOut(string requestId) => TimedOutIds.Add(requestId);
    }

    private static string Envelope(string kind, string id, string payload = "{\"session_id\":\"s1\",\"cwd\":\"C:\\\\x\"}")
        => $"{{\"v\":1,\"kind\":\"{kind}\",\"id\":\"{id}\",\"term_program\":\"\",\"term_bundle_id\":\"\",\"pid\":1,\"ts\":1,\"payload\":{payload}}}\n";

    private NamedPipeClientStream Connect()
    {
        var client = new NamedPipeClientStream(".", _name, PipeDirection.InOut, PipeOptions.Asynchronous);
        client.Connect(2000);
        return client;
    }

    private static void Send(Stream s, string line)
    {
        var b = Encoding.UTF8.GetBytes(line);
        s.Write(b);
        s.Flush();
    }

    private static string? ReadLine(Stream s, int timeoutMs)
    {
        using var cts = new CancellationTokenSource(timeoutMs);
        var ms = new MemoryStream();
        var buf = new byte[4096];
        try
        {
            while (true)
            {
                int n = s.ReadAsync(buf, cts.Token).AsTask().GetAwaiter().GetResult();
                if (n <= 0) break;
                int nl = Array.IndexOf(buf, (byte)'\n', 0, n);
                if (nl >= 0) { ms.Write(buf, 0, nl); return Encoding.UTF8.GetString(ms.ToArray()); }
                ms.Write(buf, 0, n);
            }
        }
        catch (OperationCanceledException) { return null; }
        return ms.Length == 0 ? null : Encoding.UTF8.GetString(ms.ToArray());
    }

    [Fact]
    public void PassiveKindsGetNoneAtOnce()
    {
        using var client = Connect();
        Send(client, Envelope("stop", "p1"));
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"p1\"}", ReadLine(client, 2000));
        Assert.True(_sink.Received.TryTake(out var got, 2000));
        Assert.Equal(EventKind.Stop, got.Envelope.Kind);
        Assert.True(got.Reply(null)); // nothing waits
    }

    [Fact]
    public void BlockingKindsWaitForTheReply()
    {
        using var client = Connect();
        Send(client, Envelope("permission", "b1",
            "{\"tool_name\":\"Bash\",\"permission_suggestions\":[{\"type\":\"addRules\",\"rules\":[{\"toolName\":\"Bash\",\"ruleContent\":\"npm test:*\"}],\"behavior\":\"allow\",\"destination\":\"localSettings\"}]}"));
        Assert.True(_sink.Received.TryTake(out var got, 2000));
        Assert.Equal(EventKind.Permission, got.Envelope.Kind);
        Assert.True(got.Reply(new HookReply { Decision = Decision.Allow, Always = true }));
        Assert.Equal("{\"always\":true,\"decision\":\"allow\",\"id\":\"b1\",\"updated_permissions\":[{\"behavior\":\"allow\",\"destination\":\"localSettings\",\"rules\":[{\"ruleContent\":\"npm test:*\",\"toolName\":\"Bash\"}],\"type\":\"addRules\"}]}",
                     ReadLine(client, 2000));
        // A second answer is refused.
        Assert.False(got.Reply(new HookReply { Decision = Decision.Deny }));
        Assert.False(_sink.Cancelled.TryTake(out _, 300));
    }

    [Fact]
    public void TheDeadlineAnswersNoneAndSaysSo()
    {
        using var client = Connect();
        Send(client, Envelope("pre_tool", "t1"));
        Assert.True(_sink.Received.TryTake(out var got, 2000));
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"t1\"}", ReadLine(client, 4000));
        Assert.True(_sink.TimedOutIds.TryTake(out var id, 2000));
        Assert.Equal("t1", id);
        Assert.False(got.Reply(new HookReply { Decision = Decision.Allow })); // too late
    }

    [Fact]
    public void AHookThatLeavesEarlyCancelsTheRequest()
    {
        ReplyHandler reply;
        using (var client = Connect())
        {
            Send(client, Envelope("permission", "c1"));
            Assert.True(_sink.Received.TryTake(out var got, 2000));
            reply = got.Reply;
        }
        Assert.True(_sink.Cancelled.TryTake(out var id, 3000));
        Assert.Equal("c1", id);
        Assert.False(reply(new HookReply { Decision = Decision.Allow })); // dropped
        Assert.False(_sink.TimedOutIds.TryTake(out _, 1500));
    }

    [Fact]
    public void ManyHooksWaitAtOnce()
    {
        var clients = Enumerable.Range(0, 5).Select(_ => Connect()).ToList();
        for (int i = 0; i < clients.Count; i++) Send(clients[i], Envelope("permission", "m" + i));
        var handlers = new Dictionary<string, ReplyHandler>();
        for (int i = 0; i < clients.Count; i++)
        {
            Assert.True(_sink.Received.TryTake(out var got, 2000));
            handlers[got.Envelope.Id] = got.Reply;
        }
        foreach (var (id, h) in handlers) Assert.True(h(new HookReply { Decision = Decision.Deny, Reason = "no " + id }));
        for (int i = 0; i < clients.Count; i++)
            Assert.Equal($"{{\"always\":false,\"decision\":\"deny\",\"id\":\"m{i}\",\"reason\":\"no m{i}\"}}", ReadLine(clients[i], 2000));
        clients.ForEach(c => c.Dispose());
    }

    [Fact]
    public void GarbageGetsNoneWithAQuestionMark()
    {
        using var client = Connect();
        Send(client, "not json\n");
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"?\"}", ReadLine(client, 2000));
    }

    // MARK: Wave 3d

    [Fact]
    public void AClientThatSaysNothingGetsNoneAfterTheReadTimeout()
    {
        using var client = Connect();
        var started = DateTime.UtcNow;
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"?\"}", ReadLine(client, 5000));
        var took = (DateTime.UtcNow - started).TotalSeconds;
        Assert.InRange(took, PipeServer.ReadTimeout - 0.5, PipeServer.ReadTimeout + 2);
        Assert.False(_sink.Received.TryTake(out _, 200));
        // The server still serves the next hook.
        using var next = Connect();
        Send(next, Envelope("stop", "after"));
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"after\"}", ReadLine(next, 2000));
    }

    [Fact]
    public async Task ALinePastTheCapIsDroppedAndTheServerCarriesOn()
    {
        using var client = Connect();
        // 9 MB with no newline: more than the 8 MB the server reads for one envelope.
        var big = Encoding.UTF8.GetBytes(Envelope("stop", "big", "{\"pad\":\"" + new string('x', 9 * 1024 * 1024) + "\"}"));
        var writer = Task.Run(() =>
        {
            try { client.Write(big); client.Flush(); return true; }
            catch (IOException) { return false; } // the server closed its end mid-way
        });
        var reply = ReadLine(client, 10_000);
        Assert.True(reply is null || reply == "{\"always\":false,\"decision\":\"none\",\"id\":\"?\"}", reply);
        await writer.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.False(_sink.Received.TryTake(out _, 300));
        using var next = Connect();
        Send(next, Envelope("stop", "small"));
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"small\"}", ReadLine(next, 2000));
    }

    [Fact]
    public void ThePipeAdmitsTheCurrentUserOnly()
    {
        using var client = Connect();
        var acl = client.GetAccessControl();
        var rules = acl.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier))
            .Cast<System.Security.AccessControl.AuthorizationRule>().ToList();
        var me = System.Security.Principal.WindowsIdentity.GetCurrent().User!;
        Assert.NotEmpty(rules);
        Assert.All(rules, r => Assert.Equal(me, r.IdentityReference));
        Assert.Equal(me, acl.GetOwner(typeof(System.Security.Principal.SecurityIdentifier)));
        Send(client, Envelope("stop", "acl"));
        ReadLine(client, 2000);
    }

    [Fact]
    public void APlanWaitsForItsOwnDeadline()
    {
        using var client = Connect();
        Send(client, Envelope("permission", "plan1", "{\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"# P\"}}"));
        Assert.True(_sink.Received.TryTake(out var got, 2000));
        Assert.True(got.Envelope.IsPlanRequest);
        var started = DateTime.UtcNow;
        Assert.Equal("{\"always\":false,\"decision\":\"none\",\"id\":\"plan1\"}", ReadLine(client, 6000));
        // This server's deadlines: 3 s for a plan, 1 s for anything else.
        Assert.True((DateTime.UtcNow - started).TotalSeconds > 2.3);
        Assert.True(_sink.TimedOutIds.TryTake(out var id, 2000));
        Assert.Equal("plan1", id);
    }

    [Fact]
    public void TheSinkIsCalledOnTheDispatcherInOrder()
    {
        // A dispatcher on its own STA thread stands in for the app's UI thread.
        using var ready = new ManualResetEventSlim();
        System.Windows.Threading.Dispatcher? dispatcher = null;
        var ui = new Thread(() =>
        {
            dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
            ready.Set();
            System.Windows.Threading.Dispatcher.Run();
        });
        ui.SetApartmentState(ApartmentState.STA);
        ui.IsBackground = true;
        ui.Start();
        ready.Wait();
        var sink = new ThreadSink();
        var name = "notchcode-test-" + Guid.NewGuid().ToString("N");
        var server = new PipeServer(sink, name, replyDeadline: _ => 1, dispatcher: dispatcher);
        server.Start();
        try
        {
            using (var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                client.Connect(2000);
                Send(client, Envelope("permission", "d1"));
                Assert.True(sink.Events.TryTake(out var first, 3000));
                Assert.Equal(("receive d1", ui.ManagedThreadId), first);
            }
            // The hook left: Cancel, after Receive, on the same thread.
            Assert.True(sink.Events.TryTake(out var second, 3000));
            Assert.Equal(("cancel d1", ui.ManagedThreadId), second);

            using var timed = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
            timed.Connect(2000);
            Send(timed, Envelope("pre_tool", "d2"));
            Assert.True(sink.Events.TryTake(out var third, 3000));
            Assert.Equal(("receive d2", ui.ManagedThreadId), third);
            Assert.True(sink.Events.TryTake(out var fourth, 3000));
            Assert.Equal(("timedout d2", ui.ManagedThreadId), fourth);
        }
        finally
        {
            server.Stop();
            dispatcher!.InvokeShutdown();
        }
    }

    private sealed class ThreadSink : IHookEventSink
    {
        public readonly BlockingCollection<(string, int)> Events = new();
        public void Receive(HookEnvelope envelope, ReplyHandler reply) => Events.Add(("receive " + envelope.Id, Environment.CurrentManagedThreadId));
        public void Cancel(string requestId) => Events.Add(("cancel " + requestId, Environment.CurrentManagedThreadId));
        public void TimedOut(string requestId) => Events.Add(("timedout " + requestId, Environment.CurrentManagedThreadId));
    }

    [Fact]
    public void StopClosesWaitingHooksAndFreesTheName()
    {
        var name = "notchcode-test-" + Guid.NewGuid().ToString("N");
        var sink = new RecordingSink();
        var server = new PipeServer(sink, name, replyDeadline: _ => 30);
        server.Start();
        using var waiting = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        waiting.Connect(2000);
        Send(waiting, Envelope("permission", "w1"));
        Assert.True(sink.Received.TryTake(out var got, 2000));

        server.Stop();
        Assert.Null(ReadLine(waiting, 3000));                          // the pipe ended, no reply
        Assert.False(got.Reply(new HookReply { Decision = Decision.Allow }));
        Assert.False(sink.Cancelled.TryTake(out _, 300));             // a stop is not the hook leaving

        // The name is free again at once.
        var again = new PipeServer(new RecordingSink(), name);
        again.Start();
        again.Stop();
    }

    [Fact]
    public async Task ManyClientsAtOnceEachGetTheirOwnAnswer()
    {
        var tasks = Enumerable.Range(0, 24).Select(i => Task.Run(() =>
        {
            using var c = Connect();
            Send(c, Envelope("notification", "n" + i));
            return ReadLine(c, 5000);
        })).ToArray();
        var replies = await Task.WhenAll(tasks).WaitAsync(TimeSpan.FromSeconds(15));
        for (int i = 0; i < replies.Length; i++)
            Assert.Equal($"{{\"always\":false,\"decision\":\"none\",\"id\":\"n{i}\"}}", replies[i]);
        var ids = new HashSet<string>();
        while (_sink.Received.TryTake(out var r, 500)) ids.Add(r.Envelope.Id);
        Assert.Equal(24, ids.Count);
    }

    [Fact]
    public void ASecondServerOnTheSameNameRefusesToStart()
    {
        var second = new PipeServer(new RecordingSink(), _name);
        Assert.Throws<PipeServerException>(second.Start);
    }
}
