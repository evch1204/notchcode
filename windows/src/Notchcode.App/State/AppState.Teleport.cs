// AppState.Teleport.cs
// Port of Sources/notchcode/State/AppState+Teleport.swift, Windows version (windows/PLAN.md,
// the teleport row): bringing a session's terminal to the front.
//
// macOS activates the terminal app by bundle id. Windows has no bundle ids: from the
// Claude Code process the hook reported (`pid`) the walk goes up the process tree to the first
// ancestor with a visible top-level window (Windows Terminal, conhost, wezterm, alacritty, a
// classic console's shell, ...) and brings that window up with the AttachThreadInput dance.
// VS Code and Cursor run `<exe> --reuse-window <cwd>` instead, which raises the window that has
// the folder open. Nothing else is ever run; with no window found, "No terminal found".

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Notchcode.Notch;
using Notchcode.UI;

namespace Notchcode.State;

public sealed partial class AppState
{
    /// The terminals teleport knows: TERM_PROGRAM, the name buttons show, the process names
    /// (without ".exe") that carry its window. With no window found from the session's process,
    /// the first one running wins, in this order.
    private static readonly (string? Program, string Name, string[] Processes)[] Terminals =
    [
        ("WindowsTerminal", "Terminal", ["WindowsTerminal"]),
        ("vscode", "VS Code", ["Code", "Code - Insiders"]),
        ("cursor", "Cursor", ["Cursor"]),
        ("WezTerm", "WezTerm", ["wezterm-gui"]),
        ("alacritty", "Alacritty", ["alacritty"]),
        ("mintty", "mintty", ["mintty"]),
        (null, "Console", ["conhost", "OpenConsole"]),
    ];

    /// Terminal hosts: the walk ends at one, with its window or without. Shells (cmd, powershell,
    /// pwsh) are not here: in a classic console their main window is the console's and ends the
    /// walk; under Windows Terminal they have none and the walk goes on to the terminal.
    private static readonly HashSet<string> TerminalHostNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "wezterm-gui", "alacritty", "conhost", "OpenConsole", "mintty",
    };

    /// Windows' own processes: never a session's terminal, and their windows (the desktop) must not come up.
    private static readonly HashSet<string> StopProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "explorer", "svchost", "services", "wininit", "winlogon", "sihost", "RuntimeBroker",
    };

    private static readonly HashSet<string> EditorProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Code", "Code - Insiders", "Cursor",
    };

    private static (string? Program, string Name, string[] Processes)? Terminal(string? program)
    {
        if (program is null) return null;
        foreach (var t in Terminals)
            if (string.Equals(t.Program, program, StringComparison.OrdinalIgnoreCase)) return t;
        return null;
    }

    public string TerminalName(Session? session) => Terminal(session?.TermProgram)?.Name ?? "terminal";

    public void SetNotch(double width, double height)
    {
        var next = new NotchLayout(width, height);
        if (next != Layout) Layout = next;
    }

    /// Bring the session's terminal to the front. Never runs a command, except VS Code's or
    /// Cursor's own exe with `--reuse-window <cwd>`. The session's own window first (its
    /// process tree, then its TERM_PROGRAM), else the first known terminal that is running.
    /// With none, a short "No terminal found" hint and the card stays.
    public void Teleport(Session? session)
    {
        session ??= FocusedSession;
        var target = session is null ? null : FindTerminal(session);
        if (target is null)
        {
            var hwnd = FirstRunningTerminalWindow(Terminal(session?.TermProgram)?.Processes);
            if (hwnd != IntPtr.Zero) target = new TeleportTarget(hwnd, null);
        }
        if (target is null)
        {
            Flash("No terminal found");
            return;
        }
        var cwd = session?.Cwd ?? "";
        Fold(() =>
        {
            if (target.EditorExe is { } exe && cwd.Length > 0 && Directory.Exists(cwd))
            {
                if (!OpenInEditor(exe, cwd) && target.Window != IntPtr.Zero) BringToFront(target.Window);
            }
            else if (target.Window != IntPtr.Zero)
            {
                BringToFront(target.Window);
            }
        });
    }

    /// Teleport fold: the card folds into the notch (height, then width) and the terminal is
    /// brought forward at the 0.15 s mark so it rises behind. Reduce Motion: activate at once.
    private void Fold(Action activate)
    {
        SkipFocusReturn = true;
        if (IsCardOpen && !Theme.Motion.ReduceMotion)
        {
            TeleportFold = true;
            RunAfter(Theme.Motion.TeleportActivateAt, activate);
            RunAfter(Theme.Motion.FoldTotal, () => TeleportFold = false);
        }
        else
        {
            activate();
        }
        CloseCard();
    }

    // MARK: - Finding the window

    /// What teleport brings up: a top-level window, or an editor exe to run with `--reuse-window`
    /// (its window too, as the fallback when the run fails).
    internal sealed record TeleportTarget(IntPtr Window, string? EditorExe);

    private TeleportTarget? FindTerminal(Session session)
    {
        if (!SessionPids.TryGetValue(session.Id, out var pid) || pid <= 0) return null;
        return FindTerminalFrom(pid);
    }

    /// The walk up from `pid` (the Claude Code process a hook reported). `visited` (tests)
    /// collects the (pid, exe name) of every process the walk looked at, in order.
    internal static TeleportTarget? FindTerminalFrom(int pid, List<(int Pid, string Name)>? visited = null)
    {
        var tree = ProcessTree.Snapshot();
        var seen = new HashSet<int>();
        int current = pid;
        for (int depth = 0; depth < 32 && current > 0 && seen.Add(current); depth++)
        {
            if (!tree.TryGetValue(current, out var entry)) break;
            var name = Path.GetFileNameWithoutExtension(entry.ExeName);
            visited?.Add((current, name));
            // Windows' own shell: its window is the desktop, never the session's terminal.
            if (StopProcessNames.Contains(name)) break;
            if (EditorProcessNames.Contains(name))
            {
                // The integrated terminal's parent is one of the editor's helper processes; the
                // exe is the same, so its path is enough.
                var exe = ProcessTree.ExePath(current);
                var window = MainWindow(current);
                if (window == IntPtr.Zero) window = FirstRunningTerminalWindow([name]);
                if (exe is not null) return new TeleportTarget(window, exe);
                if (window != IntPtr.Zero) return new TeleportTarget(window, null);
            }
            var hwnd = MainWindow(current);
            if (hwnd != IntPtr.Zero) return new TeleportTarget(hwnd, null);
            // A terminal host with no window to show: walking further would only find unrelated
            // windows. A shell (cmd, pwsh) under Windows Terminal has none: keep walking to the terminal.
            if (TerminalHostNames.Contains(name)) break;
            // Pid reuse: a "parent" that started after its child is not its parent.
            if (ProcessTree.StartTime(entry.ParentPid) is { } ps && ProcessTree.StartTime(current) is { } cs && ps > cs) break;
            current = entry.ParentPid;
        }
        return null;
    }

    /// A process's visible main window, or zero.
    private static IntPtr MainWindow(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            var h = p.MainWindowHandle;
            return h != IntPtr.Zero && Native.IsWindowVisible(h) ? h : IntPtr.Zero;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return IntPtr.Zero;
        }
    }

    /// The first running process (by the session's own terminal first, then the known order)
    /// with a visible main window.
    private static IntPtr FirstRunningTerminalWindow(string[]? preferred)
    {
        var names = new List<string>();
        if (preferred is not null) names.AddRange(preferred);
        foreach (var t in Terminals) names.AddRange(t.Processes);
        foreach (var name in names.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            Process[] list;
            try { list = Process.GetProcessesByName(name); }
            catch (InvalidOperationException) { continue; }
            try
            {
                foreach (var p in list)
                {
                    var h = p.MainWindowHandle;
                    if (h != IntPtr.Zero && Native.IsWindowVisible(h)) return h;
                }
            }
            finally
            {
                foreach (var p in list) p.Dispose();
            }
        }
        return IntPtr.Zero;
    }

    // MARK: - Bringing it up

    /// `<Code.exe> --reuse-window <cwd>`: the editor raises the window that has the folder open.
    /// The argument list is passed as is (no shell), so the cwd cannot be read as a command.
    private static bool OpenInEditor(string exe, string cwd)
    {
        try
        {
            var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true };
            info.ArgumentList.Add("--reuse-window");
            info.ArgumentList.Add(cwd);
            using var p = Process.Start(info);
            return p is not null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
    }

    /// Restores a minimised window and makes it the foreground window. Windows only lets the
    /// foreground thread hand the foreground on, so this thread attaches to it for the call.
    private static void BringToFront(IntPtr hwnd)
    {
        if (Native.IsIconic(hwnd)) Native.ShowWindow(hwnd, Native.SW_RESTORE);
        var foreground = Native.GetForegroundWindow();
        uint foregroundThread = foreground == IntPtr.Zero ? 0 : Native.GetWindowThreadProcessId(foreground, out _);
        uint thisThread = Native.GetCurrentThreadId();
        bool attached = foregroundThread != 0 && foregroundThread != thisThread
                        && Native.AttachThreadInput(thisThread, foregroundThread, true);
        try
        {
            Native.BringWindowToTop(hwnd);
            Native.SetForegroundWindow(hwnd);
        }
        finally
        {
            if (attached) Native.AttachThreadInput(thisThread, foregroundThread, false);
        }
    }

    // MARK: - Win32

    /// pid -> (parent pid, exe name), from one Toolhelp snapshot.
    private static class ProcessTree
    {
        internal sealed record Entry(int ParentPid, string ExeName);

        internal static Dictionary<int, Entry> Snapshot()
        {
            var result = new Dictionary<int, Entry>();
            var snap = Native.CreateToolhelp32Snapshot(Native.TH32CS_SNAPPROCESS, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return result;
            try
            {
                var entry = new Native.PROCESSENTRY32W { dwSize = (uint)Marshal.SizeOf<Native.PROCESSENTRY32W>() };
                if (!Native.Process32FirstW(snap, ref entry)) return result;
                do
                {
                    int pid = (int)entry.th32ProcessID;
                    result[pid] = new Entry((int)entry.th32ParentProcessID, entry.szExeFile ?? "");
                    entry.dwSize = (uint)Marshal.SizeOf<Native.PROCESSENTRY32W>();
                } while (Native.Process32NextW(snap, ref entry));
            }
            finally
            {
                Native.CloseHandle(snap);
            }
            return result;
        }

        /// When the process started, or null when it cannot be read (then no pid-reuse check).
        internal static DateTime? StartTime(int pid)
        {
            var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
            if (handle == IntPtr.Zero) return null;
            try
            {
                return Native.GetProcessTimes(handle, out var creation, out _, out _, out _)
                    ? DateTime.FromFileTimeUtc(creation)
                    : null;
            }
            finally
            {
                Native.CloseHandle(handle);
            }
        }

        /// The process's exe path, or null.
        internal static string? ExePath(int pid)
        {
            var handle = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
            if (handle == IntPtr.Zero) return null;
            try
            {
                var buffer = new char[32768];
                uint size = (uint)buffer.Length;
                return Native.QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? new string(buffer, 0, (int)size) : null;
            }
            finally
            {
                Native.CloseHandle(handle);
            }
        }
    }

    private static class Native
    {
        internal const uint TH32CS_SNAPPROCESS = 0x00000002;
        internal const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        internal const int SW_RESTORE = 9;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct PROCESSENTRY32W
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern bool Process32FirstW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern bool Process32NextW(IntPtr hSnapshot, ref PROCESSENTRY32W lppe);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetProcessTimes(IntPtr hProcess, out long lpCreationTime, out long lpExitTime, out long lpKernelTime, out long lpUserTime);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern bool QueryFullProcessImageNameW(IntPtr hProcess, uint dwFlags, [Out] char[] lpExeName, ref uint lpdwSize);

        [DllImport("kernel32.dll")]
        internal static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        internal static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

        [DllImport("user32.dll")]
        internal static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        internal static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool IsWindowVisible(IntPtr hWnd);
    }
}
