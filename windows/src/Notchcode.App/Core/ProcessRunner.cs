// ProcessRunner.cs
// Port of Sources/notchcode/Core/ProcessRunner.swift.
// Runs one executable off the UI thread and awaits it without holding a thread. Shared by
// the Git tool (`git.exe`) and the Usage tool's `claude.exe -p /usage`. No window, stdin
// closed, UTF-8 output. Both outputs are drained as they come so a large output never fills
// a pipe, and kept up to `Theme.Limits.GitOutputBytes` each. The run is over when the process
// exits; a helper that outlives it and still holds a pipe open (an ssh ControlPersist) gets
// `Theme.Timing.ProcessKillGrace` to finish writing, then its output is taken as it stands.
// Past the timeout the whole process tree is killed (Windows has no SIGTERM for a console
// process, so there is no polite first step).

using System.IO;
using System.Diagnostics;
using System.Text;
using Notchcode.UI;

namespace Notchcode.Core;

public static class ProcessRunner
{
    public sealed record Result(int Status, string Out, string Err, bool TimedOut = false);

    /// Runs `executable` with `arguments` (each passed as its own argument, never through a
    /// shell). `environment` overrides the inherited environment: a value sets the variable,
    /// null removes it. `timeout` is in seconds.
    public static async Task<Result> RunAsync(string executable,
                                              IEnumerable<string> arguments,
                                              string? cwd = null,
                                              IReadOnlyDictionary<string, string?>? environment = null,
                                              double timeout = 30,
                                              CancellationToken cancellationToken = default)
    {
        var name = Path.GetFileName(executable);
        var failed = new Result(-1, "", "could not run " + name);

        var psi = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        foreach (var a in arguments) psi.ArgumentList.Add(a);
        if (!string.IsNullOrEmpty(cwd)) psi.WorkingDirectory = cwd;
        if (environment is not null)
        {
            foreach (var (key, value) in environment)
            {
                if (value is null) psi.Environment.Remove(key);
                else psi.Environment[key] = value;
            }
        }

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        process.Exited += (_, _) => exited.TrySetResult();
        try
        {
            if (!process.Start()) return failed;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or PlatformNotSupportedException)
        {
            return failed;
        }

        // stdin closed: a command that asks for input reads EOF at once.
        try { process.StandardInput.Close(); } catch (IOException) { }

        int cap = (int)Theme.Limits.GitOutputBytes;
        var outBuf = new MemoryStream();
        var errBuf = new MemoryStream();
        var outTask = Drain(process.StandardOutput.BaseStream, outBuf, cap);
        var errTask = Drain(process.StandardError.BaseStream, errBuf, cap);

        bool timedOut = false;
        using (var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            var delay = Task.Delay(TimeSpan.FromSeconds(Math.Max(0, timeout)), timeoutCts.Token);
            var first = await Task.WhenAny(exited.Task, delay).ConfigureAwait(false);
            if (first != exited.Task)
            {
                timedOut = true;
                try { process.Kill(entireProcessTree: true); }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
                await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(Theme.Timing.ProcessKillGrace))).ConfigureAwait(false);
            }
            timeoutCts.Cancel();
        }

        // Exited: give the readers the grace to reach EOF, then take what they have.
        var drained = Task.WhenAll(outTask, errTask);
        await Task.WhenAny(drained, Task.Delay(TimeSpan.FromSeconds(Theme.Timing.ProcessKillGrace))).ConfigureAwait(false);
        static string Text(MemoryStream ms)
        {
            lock (ms) return Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
        }

        int status;
        try { status = process.HasExited ? process.ExitCode : -1; }
        catch (InvalidOperationException) { status = -1; }
        return new Result(timedOut ? -1 : status, Text(outBuf), Text(errBuf), timedOut);
    }

    /// Reads `stream` to its end, keeping the first `cap` bytes and discarding the rest.
    private static async Task Drain(Stream stream, MemoryStream kept, int cap)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (true)
            {
                int n = await stream.ReadAsync(buffer).ConfigureAwait(false);
                if (n <= 0) break;
                int room = cap - (int)kept.Length;
                if (room > 0) lock (kept) kept.Write(buffer, 0, Math.Min(room, n));
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException) { }
    }
}
