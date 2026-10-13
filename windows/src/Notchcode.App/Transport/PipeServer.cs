// PipeServer.cs
// Port of Sources/notchcode/Transport/SocketServer.swift: the named pipe the hook exe talks
// to, \\.\pipe\notchcode-<username>, readable and writable by the current user only.
//
// Protocol (see Contract.cs):
//   client -> app   one line of JSON, a HookEnvelope
//   app -> client   one line of JSON, a HookReply, then the app closes
//
// Passive kinds get `decision: none` at once, so the hook exits immediately.
// Blocking kinds (permission, pre_tool) stay open until the sink calls its
// reply handler or `Theme.Timing.ReplyDeadline(plan)` passes, whichever comes first.
//
// A reply that allows "always" carries one extra key, `updated_permissions`: the
// app's own rules (a plan's Auto-accept), else the PermissionRequest payload's
// `permission_suggestions` verbatim (HookReply.ReplyLine).
//
// While a blocking request waits, a read stays pending on the pipe: the hook sends nothing
// after its line, so the read completes only when the hook goes away (the owner answered in
// the terminal, or Claude Code killed it at its timeout). The connection is then marked dead,
// the deadline is cancelled, and the sink gets `Cancel(requestId)`. A reply that arrives after
// that is dropped silently. (A pipe has no half-close, so the macOS nc subtlety is gone.)
//
// The sink is called on the WPF dispatcher when an Application exists (in arrival order,
// `Receive` before any `Cancel` or `TimedOut` of the same request), else inline (tests).
// Every connection runs on the thread pool; any number of hooks can wait at once.

using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Windows;
using Notchcode.UI;

namespace Notchcode.Transport;

public sealed class PipeServerException(string message) : Exception(message)
{
    public static PipeServerException AlreadyRunning(string pipe) => new("another notchcode is already listening on " + pipe);
}

public sealed class PipeServer : IDisposable
{
    /// Seconds to receive the envelope line.
    public const double ReadTimeout = 2;
    public const int MaxLineBytes = 8 * 1024 * 1024;
    /// After a reply is written, how long the server waits for the hook to read it and close.
    private const double DrainTimeout = 2;

    private readonly IHookEventSink _sink;
    private readonly string _pipeName;
    private readonly Func<bool, double> _replyDeadline;
    private readonly double _readTimeout;
    private readonly System.Windows.Threading.Dispatcher? _dispatcher;
    private readonly object _stateLock = new();
    private CancellationTokenSource? _cts;

    public PipeServer(IHookEventSink sink) : this(sink, NotchcodePaths.PipeName) { }

    /// `pipeName`, `replyDeadline` (seconds, by "is a plan"), `readTimeout` and `dispatcher`
    /// (the sink's thread; default the WPF application's) exist for tests and harnesses; the
    /// app uses `PipeServer(sink)`.
    public PipeServer(IHookEventSink sink, string pipeName, Func<bool, double>? replyDeadline = null, double? readTimeout = null,
                      System.Windows.Threading.Dispatcher? dispatcher = null)
    {
        _sink = sink;
        _pipeName = pipeName;
        _replyDeadline = replyDeadline ?? Theme.Timing.ReplyDeadline;
        _readTimeout = readTimeout ?? ReadTimeout;
        _dispatcher = dispatcher;
    }

    public void Dispose() => Stop();

    // MARK: Lifecycle

    /// Starts listening. Throws PipeServerException when another notchcode already owns the pipe.
    public void Start()
    {
        lock (_stateLock)
        {
            if (_cts is not null) return;

            // A server that answers means a second copy of the app.
            if (CanConnect(_pipeName)) throw PipeServerException.AlreadyRunning(_pipeName);

            NamedPipeServerStream first;
            try { first = CreateInstance(_pipeName, firstInstance: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw PipeServerException.AlreadyRunning(_pipeName);
            }
            var cts = new CancellationTokenSource();
            _cts = cts;
            _acceptLoop = Task.Run(() => AcceptLoop(first, cts.Token));
        }
    }

    /// Stops listening and closes every open connection without a reply (a waiting hook sees
    /// the pipe end and prints nothing, as when the app quits). Returns once the pipe is gone,
    /// so a new server can start on the same name at once. The sink hears nothing more.
    public void Stop()
    {
        Task? loop;
        lock (_stateLock)
        {
            _cts?.Cancel();
            _cts = null;
            loop = _acceptLoop;
            _acceptLoop = null;
        }
        try { loop?.Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
        foreach (var conn in _connections.Keys) conn.Abort();
    }

    private Task? _acceptLoop;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<ClientConnection, byte> _connections = new();

    // MARK: Accept

    private async Task AcceptLoop(NamedPipeServerStream next, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var server = next;
            try
            {
                await server.WaitForConnectionAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { server.Dispose(); return; }
            catch (Exception e) when (e is IOException or ObjectDisposedException)
            {
                server.Dispose();
                if (Retry() is not { } again) return;
                next = again;
                continue;
            }
            // The next instance is listening before this client is served.
            var listening = Retry();
            _ = Task.Run(() => Handle(server));
            if (listening is null) return;
            next = listening;
        }
        next.Dispose();

        // A new instance, retried every 250 ms while it fails; null once stopped.
        NamedPipeServerStream? Retry()
        {
            while (!token.IsCancellationRequested)
            {
                try { return CreateInstance(_pipeName, firstInstance: false); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { token.WaitHandle.WaitOne(250); }
            }
            return null;
        }
    }

    /// One pipe instance, current user only, asynchronous, byte mode.
    private static NamedPipeServerStream CreateInstance(string name, bool firstInstance)
    {
        var security = new PipeSecurity();
        var user = WindowsIdentity.GetCurrent().User!;
        security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.SetOwner(user);
        var options = PipeOptions.Asynchronous | (firstInstance ? PipeOptions.FirstPipeInstance : PipeOptions.None);
        return NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                                               PipeTransmissionMode.Byte, options, 0, 0, security);
    }

    // MARK: One client

    private async Task Handle(NamedPipeServerStream pipe)
    {
        var conn = new ClientConnection(pipe, c => _connections.TryRemove(c, out _));
        _connections[conn] = 0;
        bool stopped;
        lock (_stateLock) stopped = _cts is null;
        if (stopped) { conn.Abort(); return; }
        string? line;
        try { line = await ReadLine(pipe, _readTimeout).ConfigureAwait(false); }
        catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException) { line = null; }

        if (string.IsNullOrEmpty(line))
        {
            // No envelope line before the timeout.
            await conn.Finish(HookReply.ReplyLine(null, "?", JsonValue.Null)).ConfigureAwait(false);
            return;
        }

        var envelope = HookEnvelope.FromLine(line);
        if (envelope is null)
        {
            await conn.Finish(HookReply.ReplyLine(null, "?", JsonValue.Null)).ConfigureAwait(false);
            return;
        }

        var id = envelope.Id;
        if (envelope.IsBlocking)
        {
            var payload = envelope.Payload;
            var sink = _sink;
            // Order matters: `Receive` is queued before the watcher can queue `Cancel`, so the
            // sink always sees Receive first. The only deadline enforced for a request; the
            // card's countdown draws the same value, so the owner can never press Allow after
            // the hook was told "none".
            ReplyHandler replyHandler = r => conn.FinishSync(HookReply.ReplyLine(r, id, payload));
            conn.ArmDeadline(_replyDeadline(envelope.IsPlanRequest), HookReply.ReplyLine(null, id, JsonValue.Null), () =>
            {
                // The hook got "none": the terminal prompt waits now. The app drops the request
                // the timed-out way, so a late press can never look answered.
                OnUi(() => sink.TimedOut(id));
            });
            Deliver(envelope, replyHandler);
            conn.WatchForHangup(() => OnUi(() => sink.Cancel(id)));
        }
        else
        {
            conn.FinishSync(HookReply.ReplyLine(null, id, JsonValue.Null)); // written and closed in the background
            Deliver(envelope, _ => true); // nothing waits
        }
    }

    /// Calls the sink on the UI thread, in arrival order.
    private void Deliver(HookEnvelope envelope, ReplyHandler reply)
    {
        var sink = _sink;
        OnUi(() => sink.Receive(envelope, reply));
    }

    private void OnUi(Action action)
    {
        var dispatcher = _dispatcher ?? Application.Current?.Dispatcher;
        if (dispatcher is null) { action(); return; }
        dispatcher.BeginInvoke(action);
    }

    // MARK: Helpers

    /// Reads up to the first newline (or EOF). Null on timeout with nothing read, past the cap,
    /// or on error. A trailing "\r" is dropped.
    private static async Task<string?> ReadLine(Stream pipe, double timeout)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        var data = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (data.Length < MaxLineBytes)
        {
            int n;
            try { n = await pipe.ReadAsync(buffer, cts.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return null; }
            if (n > 0)
            {
                int nl = Array.IndexOf(buffer, (byte)0x0A, 0, n);
                if (nl >= 0)
                {
                    data.Write(buffer, 0, nl);
                    return Decode(data);
                }
                data.Write(buffer, 0, n);
            }
            else
            {
                return data.Length == 0 ? null : Decode(data); // EOF without newline: take what we have
            }
        }
        return null;

        static string Decode(MemoryStream ms)
            => Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length).TrimEnd('\r');
    }

    /// True when a server answers on the pipe within a moment.
    private static bool CanConnect(string name)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.None);
            client.Connect(100);
            return true;
        }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            // Unauthorized: the pipe exists but belongs to someone else; not a second copy of ours.
            return false;
        }
    }

    /// One accepted connection. `Finish` writes a line and closes, exactly once, from any
    /// thread. `WatchForHangup` notices the client leaving first; after that `Finish` is a no-op.
    private sealed class ClientConnection(NamedPipeServerStream pipe, Action<ClientConnection> onClosed)
    {
        /// Closes without a reply and without telling the sink (the server is stopping).
        public void Abort()
        {
            CancellationTokenSource? deadline;
            lock (_lock)
            {
                _finished = true;
                deadline = _deadline;
                _deadline = null;
            }
            deadline?.Cancel();
            Close();
        }

        private readonly object _lock = new();
        private bool _finished;
        private CancellationTokenSource? _deadline;
        private Task<int>? _pendingRead;
        private readonly byte[] _drainBuffer = new byte[256];

        /// Replies `none` after `seconds` unless something else finished first.
        public void ArmDeadline(double seconds, string line, Action onFire)
        {
            CancellationTokenSource cts;
            lock (_lock)
            {
                if (_finished) return;
                cts = new CancellationTokenSource();
                _deadline = cts;
            }
            _ = Task.Run(async () =>
            {
                try { await Task.Delay(TimeSpan.FromSeconds(seconds), cts.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                if (FinishSync(line)) onFire();
            });
        }

        /// Watches for the client going away. `onHangup` runs once, only if the connection had
        /// not finished yet.
        public void WatchForHangup(Action onHangup)
        {
            Task<int> read;
            lock (_lock)
            {
                if (_finished) return;
                read = StartRead();
            }
            _ = read.ContinueWith(t =>
            {
                _ = t.Exception; // observed: a read that fails is a hangup like any other
                // Bytes after the envelope line are ignored; only the end of the pipe counts.
                if (t.IsCompletedSuccessfully && t.Result > 0)
                {
                    lock (_lock)
                    {
                        if (_finished) return;
                        _pendingRead = null;
                    }
                    WatchForHangup(onHangup);
                    return;
                }
                if (MarkDead()) onHangup();
            }, TaskScheduler.Default);
        }

        private Task<int> StartRead()
        {
            if (_pendingRead is { } existing) return existing;
            Task<int> read;
            try { read = pipe.ReadAsync(_drainBuffer, 0, _drainBuffer.Length); }
            catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException) { read = Task.FromResult(0); }
            _pendingRead = read;
            return read;
        }

        /// The reply handler's form: true when this call does the write (which then runs off
        /// the caller's thread), false when the connection was already finished or dead.
        public bool FinishSync(string line)
        {
            if (!Claim()) return false;
            _ = WriteAndClose(line);
            return true;
        }

        /// Returns true if this call did the write, false if the connection was already finished or dead.
        public async Task<bool> Finish(string line)
        {
            if (!Claim()) return false;
            await WriteAndClose(line).ConfigureAwait(false);
            return true;
        }

        /// Marks the connection finished and stops its deadline. True if this call did it.
        private bool Claim()
        {
            CancellationTokenSource? deadline;
            lock (_lock)
            {
                if (_finished) return false;
                _finished = true;
                deadline = _deadline;
                _deadline = null;
            }
            deadline?.Cancel();
            return true;
        }

        private async Task WriteAndClose(string line)
        {
            var bytes = Encoding.UTF8.GetBytes(line);
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(DrainTimeout));
                await pipe.WriteAsync(bytes, cts.Token).ConfigureAwait(false);
                await pipe.FlushAsync(cts.Token).ConfigureAwait(false);
                // Closing a pipe end discards what the client has not read yet: wait for the
                // hook to read the line and close its end (a read that ends), at most a moment.
                Task<int> read;
                lock (_lock) read = StartRead();
                await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(DrainTimeout), CancellationToken.None)).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException or OperationCanceledException or InvalidOperationException) { }
            Close();
        }

        /// Marks the connection dead without writing. True if this call did it.
        private bool MarkDead()
        {
            CancellationTokenSource? deadline;
            lock (_lock)
            {
                if (_finished) return false;
                _finished = true;
                deadline = _deadline;
                _deadline = null;
            }
            deadline?.Cancel();
            Close();
            return true;
        }

        private void Close()
        {
            try { pipe.Dispose(); }
            catch (Exception e) when (e is IOException or ObjectDisposedException) { }
            onClosed(this);
        }
    }
}
