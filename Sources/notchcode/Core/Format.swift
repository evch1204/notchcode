// Format.swift
// Text formatting for clocks, durations, tokens, money and paths.

import Foundation

enum Format {
    /// "2:07" for a countdown or elapsed clock; "1:02:07" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "45s", "2m 14s", "1h 3m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// "now", "12m ago", "2h ago" for when a session last did something.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let total = max(0, Int(now.timeIntervalSince(date)))
        if total < 60 { return "now" }
        if total < 3600 { return "\(total / 60)m ago" }
        return "\(total / 3600)h ago"
    }

    /// "resets in 1h 52m" when close, "resets Thu 3:40 PM" when further out.
    static func resets(at date: Date, now: Date = Date()) -> String {
        let total = max(0, Int(date.timeIntervalSince(now)))
        if Double(total) < Theme.Timing.resetRelativeWindow {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return "resets in " + (hours > 0 ? "\(hours)h \(minutes)m" : "\(max(1, minutes))m")
        }
        return "resets " + weekdayTime.string(from: date)
    }

    /// "limits updated now", "limits updated 3m ago", then "limits as of 2:14 PM" (today)
    /// or "limits as of Thu 3:40 PM".
    static func limitsAsOf(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age < Theme.Timing.limitsRelativeWindow {
            return "limits updated " + ago(date, now: now)
        }
        let formatter = Calendar.current.isDate(date, inSameDayAs: now) ? time : weekdayTime
        return "limits as of " + formatter.string(from: date)
    }

    /// "reset at 3:40 PM" for a limit window that has already rolled over.
    static func resetAt(_ date: Date, now: Date = Date()) -> String {
        let formatter = Calendar.current.isDate(date, inSameDayAs: now) ? time : weekdayTime
        return "reset at " + formatter.string(from: date)
    }

    /// A tool's short name: "Bash" stays "Bash"; an MCP tool
    /// ("mcp__claude_ai_Google_Calendar__complete_authentication") becomes its last part.
    static func toolName(_ tool: String) -> String {
        guard mcpServer(tool) != nil else { return tool }
        return tool.components(separatedBy: mcpSeparator).last ?? tool
    }

    /// The MCP server of an "mcp__server__tool" name, else nil.
    static func mcpServer(_ tool: String) -> String? {
        let parts = tool.components(separatedBy: mcpSeparator)
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        return parts[1..<(parts.count - 1)].joined(separator: mcpSeparator)
    }

    private static let mcpSeparator = "__"

    /// "1:10 PM" (the owner's clock format): when a turn started.
    static func timeOfDay(_ date: Date) -> String {
        time.string(from: date)
    }

    /// "1 turn", "14 turns".
    static func turns(_ count: Int) -> String {
        count == 1 ? "1 turn" : "\(count) turns"
    }

    /// "1 quiet turn", "4 quiet turns".
    static func quietTurns(_ count: Int) -> String {
        count == 1 ? "1 quiet turn" : "\(count) quiet turns"
    }

    /// "started 1:10 PM".
    static func started(_ date: Date) -> String {
        "started " + time.string(from: date)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let weekdayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return f
    }()

    /// Token counts the way Claude Code prints them: "812", "357.2k", "1.9M", "200k", "1M".
    static func tokens(_ count: Int) -> String {
        func trimmed(_ value: Double) -> String {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        if count >= 1_000_000 { return trimmed(Double(count) / 1_000_000) + "M" }
        if count >= 1_000 {
            let k = (Double(count) / 100).rounded() / 10
            return k >= 1_000 ? trimmed(Double(count) / 1_000_000) + "M" : trimmed(k) + "k"
        }
        return "\(count)"
    }

    /// "1 file", "3 files".
    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// Percent values arrive as 0-100.
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "… 9 more lines" ("… 1 more line"), or "… more lines" when the count is not known.
    static func moreLines(_ count: Int?) -> String {
        guard let count, count > 0 else { return Theme.Glyphs.ellipsis + " more lines" }
        return Theme.Glyphs.ellipsis + (count == 1 ? " 1 more line" : " \(count) more lines")
    }

    static func added(_ count: Int) -> String { "+\(count)" }
    static func removed(_ count: Int) -> String { Theme.Glyphs.minus + "\(count)" }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The open card's status line: "main · opus · Editing", with the start time after the
    /// model when another session shares the folder ("main · opus · started 1:10 PM").
    static func statusSubtitle(_ session: Session, model: String?, started: Date?, verb: String?) -> String {
        var extras: [String] = []
        if let model { extras.append(model) }
        if let started { extras.append(Format.started(started)) }
        if let verb { extras.append(verb) }
        return sessionSubtitle(session, extra: extras.joined(separator: Theme.Glyphs.separator))
    }

    /// "main · Editing": the branch, then extras. The worktree is already in `displayFull`.
    static func sessionSubtitle(_ session: Session, extra: String? = nil) -> String {
        var parts: [String] = []
        if let branch = session.branch { parts.append(branch) }
        if let extra, !extra.isEmpty { parts.append(extra) }
        return parts.joined(separator: Theme.Glyphs.separator)
    }

    /// "1 worktree", "2 worktrees".
    static func worktrees(_ count: Int) -> String {
        count == 1 ? "1 worktree" : "\(count) worktrees"
    }

    /// "1 session", "3 sessions".
    static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    /// "1 agent", "3 agents".
    static func agents(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }

    /// "2 working · 1 waiting · 3 agents", skipping zero counts.
    static func sessionCounts(working: Int, waiting: Int, done: Int, idle: Int, agents: Int) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if done > 0 { parts.append("\(done) done") }
        if idle > 0 { parts.append("\(idle) idle") }
        if agents > 0 { parts.append(Format.agents(agents)) }
        return parts.joined(separator: Theme.Glyphs.separator)
    }

    /// A state in a word: the verb while working ("Editing"), else Needs you, Done, Idle.
    static func stateText(_ state: SessionState, verb: String?) -> String {
        switch state {
        case .working: return verb ?? "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    /// A permission mode in a word: "bypass", "plan", "accept edits", "don't ask". Default and auto (the owner's everyday modes) show nothing.
    /// Nil for the default mode and for anything unknown, which show nothing.
    static func permissionModeLabel(_ raw: String?) -> String? {
        switch raw {
        case "bypassPermissions": return "bypass"
        case "plan": return "plan"
        case "acceptEdits": return "accept edits"
        case "dontAsk": return "don't ask"
        default: return nil
        }
    }

    /// "+1 session", "+3 sessions": the other sessions beside the one the wings name.
    static func otherSessions(_ count: Int) -> String {
        count == 1 ? "+1 session" : "+\(count) sessions"
    }

    /// "1 other session", "3 other sessions".
    static func otherSessionsHelp(_ count: Int) -> String {
        count == 1 ? "1 other session" : "\(count) other sessions"
    }
}

/// The main name is the repository; the worktree is the sub line. A plain checkout has no sub.
extension Session {
    var displayName: String { repoName ?? worktreeName }
    var displaySub: String? {
        guard let repo = repoName, repo != worktreeName else { return nil }
        return worktreeName
    }
    /// "notchcode · ponyfish" for a worktree, "notchcode" for a plain checkout. Views show it
    /// with middle truncation, so a long pair keeps both ends.
    var displayFull: String {
        guard let sub = displaySub else { return displayName }
        return displayName + Theme.Glyphs.separator + sub
    }
    /// The name of the row inside its repository group: the worktree folder.
    var rowName: String { worktreeName }
}

extension Optional where Wrapped == Session {
    /// The session's full name, or the app's when there is no session.
    var displayOrApp: String { self?.displayFull ?? "notchcode" }
}

// Test change for the commit form: delete this line.
