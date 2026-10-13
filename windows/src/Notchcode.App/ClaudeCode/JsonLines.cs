// JsonLines.cs
// Port of Sources/notchcode/ClaudeCode/JSONLines.swift.
// Small helpers for reading Claude Code's JSONL transcripts: file identity (the NTFS file
// id, where macOS uses the inode), line splitting, prompt detection shared by the reader
// and the watcher, and a cache that re-parses a transcript incrementally when it only grew.
// Lines are parsed into JsonValue (key order kept), the port's `[String: Any]`.

using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using JsonValueKind = Notchcode.Core.JsonValueKind;
using Microsoft.Win32.SafeHandles;

namespace Notchcode.ClaudeCode;

/// What identifies one version of a file on disk.
public readonly record struct FileStamp(ulong FileId, double MTime, long Size)
{
    /// The last write time, UTC.
    public DateTime Modified => ContractJson.FromUnixSeconds(MTime);

    /// Null when the file cannot be read. A directory gets file id 0 and its last write time
    /// (which moves when an entry is created or removed in it).
    public static FileStamp? Of(string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        try
        {
            if (Directory.Exists(path))
            {
                var d = new DirectoryInfo(path);
                return new FileStamp(0, ContractJson.ToUnixSeconds(d.LastWriteTimeUtc), 0);
            }
            // The handle's own information, not the directory entry's (which NTFS updates lazily).
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (!GetFileInformationByHandle(handle, out var info)) return null;
            ulong id = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            long size = ((long)info.FileSizeHigh << 32) | info.FileSizeLow;
            long ft = ((long)info.LastWriteTimeHigh << 32) | info.LastWriteTimeLow;
            var mtime = DateTime.FromFileTimeUtc(ft);
            // Mix the volume serial in, so two volumes' file ids never compare equal.
            id ^= (ulong)info.VolumeSerialNumber << 48;
            return new FileStamp(id, ContractJson.ToUnixSeconds(mtime), size);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or Win32Exception)
        {
            return null;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow, CreationTimeHigh;
        public uint LastAccessTimeLow, LastAccessTimeHigh;
        public uint LastWriteTimeLow, LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh, FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out ByHandleFileInformation info);
}

public static class JsonLines
{
    /// Calls `body` with every complete line (ended by "\n") of `data` that parses as a JSON
    /// object. Returns the number of bytes consumed: everything up to and including the last
    /// newline. The unterminated remainder, if any, is left for the caller.
    public static int ForEachCompleteLine(ReadOnlySpan<byte> data, Action<JsonValue> body)
    {
        int consumed = 0;
        int start = 0;
        while (start < data.Length)
        {
            int hit = data[start..].IndexOf((byte)0x0A);
            if (hit < 0) break;
            int end = start + hit;
            if (end > start && Parse(data[start..end]) is { } line) body(line);
            start = end + 1;
            consumed = start;
        }
        return consumed;
    }

    /// One JSON object line, or null. A trailing "\r" (a CRLF file) is whitespace to the parser.
    public static JsonValue? Parse(ReadOnlySpan<byte> line)
    {
        if (line.IsEmpty) return null;
        try
        {
            var reader = new Utf8JsonReader(line, new JsonReaderOptions { MaxDepth = 256 });
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return null;
            var value = JsonValue.Read(ref reader);
            // Anything after the object but whitespace makes the line invalid, as JSONSerialization says.
            if (reader.Read()) return null;
            return value;
        }
        catch (JsonException) { return null; }
        catch (InvalidOperationException) { return null; }
        catch (ArgumentException) { return null; }
    }

    /// Reads `path` from byte `offset` to the end. Shared with the writer (Claude Code appends while we read).
    public static byte[] Read(string path, long offset)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (offset > 0) stream.Seek(offset, SeekOrigin.Begin);
        return ReadToEnd(stream, int.MaxValue);
    }

    /// Reads at most `length` bytes of `path` starting at `offset`.
    public static byte[] Read(string path, long offset, int length)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        stream.Seek(Math.Max(0, offset), SeekOrigin.Begin);
        return ReadToEnd(stream, length);
    }

    private static byte[] ReadToEnd(Stream stream, int max)
    {
        using var ms = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (ms.Length < max)
        {
            int n = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, max - ms.Length));
            if (n <= 0) break;
            ms.Write(buffer, 0, n);
        }
        return ms.ToArray();
    }

    // MARK: Small accessors (Swift's `as? String`, `as? [[String: Any]]`, ...)

    /// The member as a string, or null.
    public static string? Str(this JsonValue? v, string key) => v?[key]?.StringValue;

    /// True only when the member is the boolean true.
    public static bool IsTrue(this JsonValue? v, string key) => v?[key]?.BoolValue == true;

    /// An array of objects, or null when it is not an array or holds anything but objects.
    public static IReadOnlyList<JsonValue>? Objects(this JsonValue? v)
    {
        if (v?.ArrayValue is not { } list) return null;
        foreach (var item in list) if (item.Kind != JsonValueKind.Object) return null;
        return list;
    }

    /// An object member, or null when absent or not an object.
    public static JsonValue? Obj(this JsonValue? v, string key)
        => v?[key] is { Kind: JsonValueKind.Object } o ? o : null;

    // MARK: Prompts

    /// The owner's prompt text for a user line, or null when the line is a tool result, meta,
    /// an interruption or other noise. Slash commands come back as typed ("/review 12").
    public static string? PromptText(JsonValue line)
    {
        if (line.Str("type") != "user") return null;
        if (line.IsTrue("isMeta")) return null;
        if (UserText(line) is not { } text) return null;
        if (text.StartsWith("[Request interrupted", StringComparison.Ordinal)) return null;

        // Slash commands are recorded as tags; show them as the owner typed them.
        if (TagBody(text, "command-name") is { } name)
        {
            var args = TagBody(text, "command-args") ?? "";
            return args.Length == 0 ? name : name + " " + args;
        }
        if (TagBody(text, "bash-input") is { } cmd) return "! " + cmd;
        string[] noise = ["<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
                          "<command-message>", "<task-notification>", "<system-reminder>",
                          "<bash-stdout>", "<bash-stderr>"];
        foreach (var n in noise) if (text.StartsWith(n, StringComparison.Ordinal)) return null;
        return text;
    }

    /// The trimmed text of a user message that is not a tool result. Null for tool results
    /// and empty text.
    public static string? UserText(JsonValue line)
    {
        if (line.Obj("message") is not { } message) return null;
        string text;
        if (message.Str("content") is { } s)
        {
            text = s;
        }
        else if (message["content"].Objects() is { } blocks)
        {
            if (blocks.Any(b => b.Str("type") == "tool_result")) return null;
            text = string.Join("\n", blocks.Where(b => b.Str("type") == "text")
                                           .Select(b => b.Str("text"))
                                           .OfType<string>());
        }
        else
        {
            return null;
        }
        text = text.Trim();
        return text.Length == 0 ? null : text;
    }

    public static string? TagBody(string text, string tag)
    {
        var open = "<" + tag + ">";
        int o = text.IndexOf(open, StringComparison.Ordinal);
        if (o < 0) return null;
        int bodyStart = o + open.Length;
        int c = text.IndexOf("</" + tag + ">", bodyStart, StringComparison.Ordinal);
        if (c < 0) return null;
        var body = text[bodyStart..c].Trim();
        return body.Length == 0 ? null : body;
    }
}

/// Caches a value derived from a JSONL file by feeding its lines to a builder.
/// Unchanged file (same file id, mtime, size): the cached value. File grew in place: only the
/// appended lines are fed to a copy of the saved builder. Anything else (shrunk, replaced,
/// rewritten at the same size): a full re-parse. Claude Code only appends to transcripts.
/// A trailing line without its newline yet is parsed for the returned value but not saved
/// into the builder, so it is read again once complete. Thread-safe.
///
/// The Swift builders are value types; here `clone` makes the copy a value type would.
public sealed class IncrementalCache<TBuilder, TValue>
{
    private sealed record Entry(FileStamp Stamp, long Offset, TBuilder Builder, TValue Value);

    private readonly Func<TBuilder> _make;
    private readonly Action<TBuilder, JsonValue> _consume;
    private readonly Func<TBuilder, TBuilder> _clone;
    private readonly Func<TBuilder, TValue> _finish;
    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);

    public IncrementalCache(Func<TBuilder> make, Action<TBuilder, JsonValue> consume,
                            Func<TBuilder, TBuilder> clone, Func<TBuilder, TValue> finish)
    {
        _make = make;
        _consume = consume;
        _clone = clone;
        _finish = finish;
    }

    /// Throws FileNotFoundException when the file cannot be read.
    public TValue Value(string path)
    {
        if (FileStamp.Of(path) is not { } stamp)
        {
            lock (_lock) _entries.Remove(path);
            throw new FileNotFoundException("No such file", path);
        }
        lock (_lock)
        {
            TBuilder builder;
            long offset;
            if (_entries.TryGetValue(path, out var e))
            {
                if (e.Stamp == stamp) return e.Value;
                if (e.Stamp.FileId == stamp.FileId && stamp.Size > e.Stamp.Size && stamp.Size >= e.Offset)
                {
                    // The saved builder stays as it was (the entry may be read again on a failure).
                    builder = _clone(e.Builder);
                    offset = e.Offset;
                }
                else
                {
                    builder = _make();
                    offset = 0;
                }
            }
            else
            {
                builder = _make();
                offset = 0;
            }

            var data = JsonLines.Read(path, offset);
            int consumed = JsonLines.ForEachCompleteLine(data, line => _consume(builder, line));
            offset += consumed;

            var forValue = builder;
            if (consumed < data.Length && JsonLines.Parse(data.AsSpan(consumed)) is { } tail)
            {
                forValue = _clone(builder);
                _consume(forValue, tail);
            }
            var value = _finish(forValue);
            _entries[path] = new Entry(stamp, offset, builder, value);
            return value;
        }
    }

    public void Forget(string path)
    {
        lock (_lock) _entries.Remove(path);
    }

    /// Drops every entry whose path starts with `prefix` (a directory ending in a separator).
    public void ForgetUnder(string prefix)
    {
        lock (_lock)
        {
            foreach (var key in _entries.Keys.Where(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToList())
                _entries.Remove(key);
        }
    }
}
