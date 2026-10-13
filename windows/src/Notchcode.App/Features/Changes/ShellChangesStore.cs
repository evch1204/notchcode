// ShellChangesStore.cs
// Port of Sources/notchcode/Features/Changes/ShellChangesStore.swift.
// Keeps each session's shell changes (files a Bash command changed, per turn) on disk, so a
// relaunch of the app does not lose them. The transcript cannot bring them back: background
// agents edit with `sed`, heredocs and scripts, which leave no Edit or Write call to read.
// One JSON file per session under %LOCALAPPDATA%\notchcode\shell-changes\.
// Files unused for `Theme.Timing.ShellChangesKeep` are dropped the first time any is read.

using System.IO;
using System.Text.Json;
using Notchcode.Core;
using Notchcode.UI;

namespace Notchcode.Features.Changes;

public static class ShellChangesStore
{
    private static string Directory => NotchcodePaths.ShellChangesDirectory;

    private static string PathFor(string sessionId)
    {
        var safe = new string(sessionId.Where(c => char.IsLetter(c) || char.IsNumber(c) || c == '-').ToArray());
        return System.IO.Path.Combine(Directory, safe + ".json");
    }

    /// Writes run one after another, off the UI thread (the Swift serial queue).
    private static Task queue = Task.CompletedTask;
    private static readonly object queueLock = new();
    private static bool pruned;

    private static void Enqueue(Action work)
    {
        lock (queueLock)
        {
            queue = queue.ContinueWith(_ =>
            {
                try { work(); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException) { }
            }, TaskScheduler.Default);
        }
    }

    /// The session's saved shell changes by turn id, or empty.
    public static Dictionary<string, List<FileChange>> Load(string sessionId)
    {
        if (!pruned)
        {
            pruned = true;
            Enqueue(Prune);
        }
        try
        {
            var path = PathFor(sessionId);
            if (!File.Exists(path)) return [];
            var text = File.ReadAllText(path);
            return JsonSerializer.Deserialize<Dictionary<string, List<FileChange>>>(text, ContractJson.Options) ?? [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            return [];
        }
    }

    /// Writes the session's shell changes in the background; an empty map removes the file.
    public static void Save(IReadOnlyDictionary<string, IReadOnlyList<FileChange>> files, string sessionId)
    {
        var target = PathFor(sessionId);
        // A snapshot: the caller's collections are immutable, but copy so the writer owns it.
        var copy = files.ToDictionary(kv => kv.Key, kv => kv.Value.ToList());
        Enqueue(() =>
        {
            if (copy.Count == 0)
            {
                if (File.Exists(target)) File.Delete(target);
                return;
            }
            var json = JsonSerializer.Serialize(copy, ContractJson.Options);
            System.IO.Directory.CreateDirectory(Directory);
            // Atomic: write beside, then move over.
            var temp = target + ".tmp";
            File.WriteAllText(temp, json);
            File.Move(temp, target, overwrite: true);
        });
    }

    private static void Prune()
    {
        if (!System.IO.Directory.Exists(Directory)) return;
        var cutoff = DateTime.UtcNow.AddSeconds(-Theme.Timing.ShellChangesKeep);
        foreach (var item in System.IO.Directory.EnumerateFiles(Directory))
        {
            DateTime date;
            try { date = File.GetLastWriteTimeUtc(item); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { date = DateTime.MinValue; }
            if (date < cutoff)
            {
                try { File.Delete(item); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
    }
}
