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
        if Double(total) < Theme.Motion.resetRelativeWindow {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return "resets in " + (hours > 0 ? "\(hours)h \(minutes)m" : "\(max(1, minutes))m")
        }
        return "resets " + weekdayTime.string(from: date)
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

    static func added(_ count: Int) -> String { "+\(count)" }
    static func removed(_ count: Int) -> String { Theme.Glyphs.minus + "\(count)" }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func directory(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
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

    /// One word for the collapsed wings: Working, Editing, Running, Needs you, Done, Idle.
    static func stateWord(_ state: SessionState, verb: String?) -> String {
        switch state {
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        case .working:
            switch verb {
            case "Editing": return "Editing"
            case "Running": return "Running"
            default: return "Working"
            }
        }
    }

    static func stateText(_ session: Session, pending: Bool = false) -> String {
        if pending { return "Needs you" }
        switch session.state {
        case .working: return session.verb ?? "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        }
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
