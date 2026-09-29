// NotchTypes.swift
// Small types shared across the notch: modes, tabs, card content, keys, session groups,
// peeks and the question preview.

import Foundation

enum NotchMode: Hashable {
    /// `resting`: sessions exist but none works or needs the owner; a dim name, nothing moves.
    case closed, resting, wings, attention, peek, card
}

/// The strip's tools, plus Settings behind the gear.
enum CardTab: Hashable {
    case changes, files, usage, git, sessions, settings

    /// The tabs the owner can move between with 1-5 and tab, left to right.
    static let browsable: [CardTab] = [.sessions, .changes, .files, .git, .usage]

    var label: String {
        switch self {
        case .changes: return "Changes"
        case .files: return "Files"
        case .usage: return "Usage"
        case .git: return "Git"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }
}

/// What the open card shows, in priority order: a waiting request, the question, Settings,
/// or the selected tool's pane. The single source for the well, the strip's right wing, the
/// bridge, the footer keys and the card's height.
enum CardContent {
    case request(PendingRequest)
    case question(QuestionPreview)
    case settings
    case tool(CardTab)
}

/// Keys the card understands, already decoded from NSEvent.
enum NotchKey: Equatable {
    case primary, deny, always, edit, escape, nextTab, previousTab, up, down, left, right, teleport, settings, copy, quit
    /// "D": open or close a request card's diff.
    case diff
    /// "/": focus the Files tab's filter field.
    case filter
    /// ⌘B: hide or show the Files tool's tree.
    case toggleTree
    /// "P": Preview or Code for a Markdown file in the Files tool; Push in the Git tool.
    case markdownMode
    /// "W": the Git tool's branch picker.
    case worktree
    /// "R": the branch picker's repository dropdown.
    case repository
    case number(Int)
}

/// One repository in the Sessions tab: its worktrees' sessions, most urgent first.
struct SessionGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var sessions: [Session]
    /// Distinct working folders in the group.
    var worktreeCount: Int { Set(sessions.map { $0.cwd }).count }
    /// A worktree checkout, or more than one folder: the header counts worktrees.
    var hasWorktrees: Bool { worktreeCount > 1 || sessions.contains { $0.displaySub != nil } }
}

/// A one-line passive notice shown for a few seconds.
/// Peeks mark completions: a finished turn, a finished subagent, and (if the owner opts in) each edit.
struct Peek: Identifiable, Equatable {
    enum Kind: Equatable { case edit, done, agent }
    var id = UUID()
    var kind: Kind
    var sessionId: String
    var title: String
    var added: Int? = nil
    var removed: Int? = nil
    var detail: String? = nil
    /// Agent peeks: the finished agent's colour slot.
    var colorIndex: Int? = nil
    var createdAt = Date()
}

/// A question Claude asked in the terminal. Read-only here: no hook can answer it.
struct QuestionPreview: Equatable {
    var sessionId: String
    var question: String
    var options: [String]
}
