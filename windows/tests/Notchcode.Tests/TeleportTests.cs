// TeleportTests.cs
// The teleport walk up the process tree, from this test process (its host is whatever runs
// the tests: a terminal, an editor, Orca), and the fold's timing against the Swift values.

using System.Diagnostics;
using System.Runtime.InteropServices;
using Notchcode.Core;
using Notchcode.State;
using Notchcode.UI;

namespace Notchcode.Tests;

public class TeleportTests
{
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [Fact]
    public void TheWalkClimbsFromTheProcessToItsHostsWindow()
    {
        var visited = new List<(int Pid, string Name)>();
        var target = AppState.FindTerminalFrom(Environment.ProcessId, visited);

        // It starts at the process itself and never visits one twice or Windows' own shell.
        Assert.Equal(Environment.ProcessId, visited[0].Pid);
        Assert.Equal(Process.GetCurrentProcess().ProcessName, visited[0].Name, StringComparer.OrdinalIgnoreCase);
        Assert.Equal(visited.Count, visited.Select(v => v.Pid).Distinct().Count());
        Assert.DoesNotContain(visited, v => v.Name.Equals("explorer", StringComparison.OrdinalIgnoreCase));

        // A window it found belongs to a process on the walk (an editor's may be any of its windows).
        if (target is { Window: var hwnd } && hwnd != IntPtr.Zero && target.EditorExe is null)
        {
            GetWindowThreadProcessId(hwnd, out var owner);
            Assert.Contains(visited, v => v.Pid == (int)owner);
        }
    }

    [Fact]
    public void AGoneProcessFindsNothing()
    {
        Assert.Null(AppState.FindTerminalFrom(0));
        Assert.Null(AppState.FindTerminalFrom(int.MaxValue - 3));
    }

    [Fact]
    public void TheFoldTimingIsTheSwiftOne()
    {
        // AppState+Teleport.swift: activate at 0.15 s, the fold flag clears at 0.9 s.
        Assert.Equal(0.15, Theme.Motion.TeleportActivateAt);
        Assert.Equal(0.9, Theme.Motion.FoldTotal);
        // (Teleport itself is not called here: it would raise a real window on this desktop.)
    }
}
