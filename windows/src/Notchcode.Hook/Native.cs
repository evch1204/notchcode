// Native.cs
// The few Win32 calls the hook needs, trim-safe (blittable P/Invoke, no reflection).

using System.Runtime.InteropServices;

namespace Notchcode.Hook;

internal static class Native
{
    private const int ErrorFileNotFound = 2;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WaitNamedPipeW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WaitNamedPipe(string name, uint timeout);

    /// False when no server has created the pipe at all (the app is not running). True when
    /// it exists, even when every instance is busy for the moment. Costs no wait when absent.
    public static bool PipeExists(string pipePath)
    {
        if (WaitNamedPipe(pipePath, 1)) return true;
        return Marshal.GetLastWin32Error() != ErrorFileNotFound;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformation
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int infoClass, out ProcessBasicInformation info, int size, out int returned);

    /// The parent process id (Claude Code, which spawned the hook), or 0.
    public static int ParentProcessId()
    {
        try
        {
            int status = NtQueryInformationProcess(new IntPtr(-1), 0, out var info, Marshal.SizeOf<ProcessBasicInformation>(), out _);
            return status == 0 ? (int)info.InheritedFromUniqueProcessId.ToInt64() : 0;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return 0; }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int which);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

    /// Makes the hook's own stdin, stdout and stderr (Claude Code's pipes) non-inheritable, so
    /// a child that outlives the hook (the status line forward, the app it launches) never
    /// holds Claude Code's pipe open. Children get their own redirected pipes instead.
    public static void KeepStdHandlesFromChildren()
    {
        const uint handleFlagInherit = 1;
        foreach (var which in new[] { -10, -11, -12 })
        {
            var h = GetStdHandle(which);
            if (h != IntPtr.Zero && h != new IntPtr(-1)) SetHandleInformation(h, handleFlagInherit, 0);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string? applicationName, char[] commandLine, IntPtr processAttributes, IntPtr threadAttributes,
                                             [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment,
                                             string? currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    /// Starts `exe` detached: no console, no inherited handles, out of Claude Code's job when
    /// the job allows it, so the app outlives the session that woke it. True when it started.
    public static bool StartDetached(string exe, string? workingDirectory)
    {
        const uint detachedProcess = 0x00000008;
        const uint createNewProcessGroup = 0x00000200;
        const uint createBreakawayFromJob = 0x01000000;
        const uint createUnicodeEnvironment = 0x00000400;
        var commandLine = ("\"" + exe + "\"\0").ToCharArray();
        foreach (var flags in new[] { detachedProcess | createNewProcessGroup | createBreakawayFromJob | createUnicodeEnvironment,
                                      detachedProcess | createNewProcessGroup | createUnicodeEnvironment })
        {
            var si = new StartupInfo { cb = Marshal.SizeOf<StartupInfo>() };
            if (CreateProcess(exe, (char[])commandLine.Clone(), IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero,
                              workingDirectory, ref si, out var pi))
            {
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                return true;
            }
        }
        return false;
    }
}
