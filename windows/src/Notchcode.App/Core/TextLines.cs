// TextLines.cs
// Port of Sources/notchcode/Core/TextLines.swift.
// Line splitting and path helpers shared by every reader of file text. "\n", "\r\n" and a
// lone "\r" each count as one line break, so a Windows file never reads as one line.

using System.IO;
namespace Notchcode.Core;

public static class TextLines
{
    /// The text between line breaks ("\n", "\r\n" or "\r"), breaks removed. Like
    /// `split(separator: "\n", omittingEmptySubsequences:)`: "a\n" gives ["a", ""].
    /// `breaksOnLoneCR: false` keeps a lone "\r" inside its line, as git does (for diff text).
    public static List<string> SplitLines(this string text, bool omittingEmptySubsequences = false, bool breaksOnLoneCR = true)
    {
        var lines = new List<string>();
        int start = 0;
        int i = 0;
        while (i < text.Length)
        {
            char c = text[i];
            if (c != '\n' && c != '\r')
            {
                i++;
                continue;
            }
            int next = i + 1;
            if (c == '\r')
            {
                if (next < text.Length && text[next] == '\n')
                {
                    next++;
                }
                else if (!breaksOnLoneCR)
                {
                    i = next;
                    continue;
                }
            }
            if (!(omittingEmptySubsequences && start == i)) lines.Add(text[start..i]);
            start = next;
            i = next;
        }
        if (!(omittingEmptySubsequences && start == text.Length)) lines.Add(text[start..]);
        return lines;
    }

    /// Ends with "\n", "\r\n" or "\r".
    public static bool EndsWithNewline(this string text)
        => text.Length > 0 && (text[^1] == '\n' || text[^1] == '\r');

    /// The lines of a text file: "" is none, and a final line break does not add an empty line.
    public static List<string> FileLines(this string text)
    {
        if (text.Length == 0) return [];
        var lines = text.SplitLines();
        if (text.EndsWithNewline()) lines.RemoveAt(lines.Count - 1);
        return lines;
    }
}

/// Paths as the hooks and transcripts give them: absolute, or relative to a session's cwd.
/// On Windows '/' and '\' are both separators and the comparison ignores case.
public static class Paths
{
    /// `path` relative to `cwd` when it lies inside it; otherwise unchanged.
    public static string Relative(string path, string? cwd)
    {
        if (string.IsNullOrEmpty(cwd)) return path;
        var normPath = path.Replace('/', '\\');
        var normCwd = cwd.Replace('/', '\\');
        var b = normCwd.EndsWith('\\') ? normCwd : normCwd + "\\";
        return normPath.StartsWith(b, StringComparison.OrdinalIgnoreCase) ? path[b.Length..] : path;
    }

    /// `path` made absolute against `cwd` ("." and ".." resolved); absolute paths and an
    /// empty cwd leave it unchanged. Never touches the disk.
    public static string Absolute(string path, string cwd)
    {
        if (IsAbsolute(path) || string.IsNullOrEmpty(cwd)) return path;
        try { return System.IO.Path.GetFullPath(System.IO.Path.Combine(cwd, path)); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return path; }
    }

    /// Working folders as Windows compares them: either slash, any case, no trailing
    /// separator. A session started from VS Code's terminal often reports "c:\..." where
    /// another reports "C:\...", and the hook and the transcript may disagree on slashes.
    public static readonly IEqualityComparer<string> CwdComparer = new CwdEquality();

    /// The comparison key of a working folder (see `CwdComparer`).
    public static string CwdKey(string cwd)
    {
        var s = cwd.Replace('/', '\\');
        if (s.Length > 3 || (s.Length > 1 && s[^1] == '\\' && s[^2] != ':')) s = s.TrimEnd('\\');
        return s.ToUpperInvariant();
    }

    private sealed class CwdEquality : IEqualityComparer<string>
    {
        public bool Equals(string? a, string? b)
            => a is null || b is null ? a == b : string.Equals(CwdKey(a), CwdKey(b), StringComparison.Ordinal);
        public int GetHashCode(string s) => StringComparer.Ordinal.GetHashCode(CwdKey(s));
    }

    /// "C:\x", "C:/x", "\\server\share" or a POSIX "/x" (paths from Git Bash or a macOS transcript).
    public static bool IsAbsolute(string path)
        => path.StartsWith('/') || path.StartsWith('\\') || System.IO.Path.IsPathFullyQualified(path);
}

/// Opens files the app only reads (permission diffs, previews, line counts). Anything but a
/// regular file is refused: a directory, a device ("NUL", "CON", "\\.\..."), a pipe.
/// Symbolic links are followed, and the checks apply to the file they point at.
public static class RegularFile
{
    /// A read stream on `path` when it is a regular file of at most `maxBytes` (no cap when null).
    /// Shared for read and write, so a file another process is writing still opens. The checks
    /// run on the open handle, so a path swapped between a check and the open cannot slip through.
    public static FileStream? Open(string path, long? maxBytes = null)
    {
        if (!LooksLikeFilePath(path)) return null;
        FileStream? stream = null;
        try
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.SafeFileHandle.IsInvalid || !stream.CanSeek) { stream.Dispose(); return null; }
            var attrs = File.GetAttributes(stream.SafeFileHandle);
            if ((attrs & (FileAttributes.Directory | FileAttributes.Device)) != 0) { stream.Dispose(); return null; }
            if (maxBytes is long cap && stream.Length > cap) { stream.Dispose(); return null; }
            return stream;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            stream?.Dispose();
            return null;
        }
    }

    /// True when `path` (followed through symbolic links) is a regular file.
    public static bool IsRegular(string path)
    {
        if (!LooksLikeFilePath(path)) return false;
        try
        {
            var info = new FileInfo(path);
            if (info.LinkTarget is not null)
            {
                if (info.ResolveLinkTarget(returnFinalTarget: true) is not FileInfo target) return false;
                info = target;
            }
            if (!info.Exists) return false;
            return (info.Attributes & (FileAttributes.Directory | FileAttributes.Device)) == 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    /// Device namespace paths (\\.\pipe\x, \\?\GLOBALROOT\...) are never regular files.
    private static bool LooksLikeFilePath(string path)
        => !string.IsNullOrEmpty(path) && !path.StartsWith(@"\\.\", StringComparison.Ordinal)
           && !path.StartsWith("//./", StringComparison.Ordinal);
}
