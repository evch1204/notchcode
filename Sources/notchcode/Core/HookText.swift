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

    /// Why the request is shown: the tool's own description, the payload's message, or what
    /// "Always" would remember (from `permission_suggestions`).
    static func permissionReason(payload: JSONValue) -> String? {
        if let text = payload["tool_input"]?["description"]?.stringValue, !text.isEmpty { return text }
        if let text = payload["message"]?.stringValue, !text.isEmpty { return text }
        guard let suggestion = payload["permission_suggestions"]?.arrayValue?.first else { return nil }
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
            if suggestion["mode"]?.stringValue == "acceptEdits" { text = "Always accepts edits" }
        case "addRules":
            let rules = suggestion["rules"]?.arrayValue ?? []
            let names = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"]?.stringValue else { return nil }
                if let content = rule["ruleContent"]?.stringValue, !content.isEmpty { return "\(tool)(\(content))" }
                return tool
            }
            if !names.isEmpty { text = "Always allows " + names.joined(separator: ", ") }
        case "addDirectories":
            let dirs = (suggestion["directories"]?.arrayValue ?? []).compactMap { $0.stringValue }
            if !dirs.isEmpty { text = "Always adds " + dirs.joined(separator: ", ") }
        default:
            break
        }
        guard let text else { return nil }
        return [text, destination].compactMap { $0 }.joined(separator: " ") + "."
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
