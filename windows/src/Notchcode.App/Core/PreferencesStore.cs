// PreferencesStore.cs
// Port of Sources/notchcode/Core/PreferencesStore.swift.
// Preferences live in %LOCALAPPDATA%\notchcode\preferences.json as one JSON object, the keys
// sorted (macOS: one blob in UserDefaults). A missing or unreadable file gives the defaults
// from Contract.cs; a key missing from the file takes its default.

using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Notchcode.Core;

public static class PreferencesStore
{
    public static Preferences Load(string? path = null)
    {
        path ??= NotchcodePaths.PreferencesFile;
        try
        {
            if (!File.Exists(path)) return new Preferences();
            var text = File.ReadAllText(path);
            return JsonSerializer.Deserialize<Preferences>(text, ContractJson.Options) ?? new Preferences();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
        {
            return new Preferences();
        }
    }

    /// Writes atomically: a temporary file beside the target, then a move over it.
    public static void Save(Preferences prefs, string? path = null)
    {
        path ??= NotchcodePaths.PreferencesFile;
        try
        {
            var node = JsonSerializer.SerializeToNode(prefs, ContractJson.Options) as JsonObject;
            if (node is null) return;
            var sorted = new JsonObject();
            foreach (var kv in node.OrderBy(kv => kv.Key, StringComparer.Ordinal).ToList())
            {
                node.Remove(kv.Key);
                sorted[kv.Key] = kv.Value;
            }
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temp, sorted.ToJsonString(ContractJson.Options));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            // Preferences are a convenience: a failed save keeps the choice for this run only.
        }
    }
}
