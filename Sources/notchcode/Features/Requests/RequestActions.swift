// RequestActions.swift
// What a pending request offers and says: its actions (Deny · middle · Allow), its
// headline and summary, and the time left before its deadline.

import SwiftUI

/// An action's part in a request: Allow (primary, white), Deny (red tint), or neutral.
enum ActionRole { case allow, deny, neutral }

/// One action of a request, as the strip, the attention row and the footer show it.
struct RequestAction {
    let title: String
    let key: String?
    let help: String
    let role: ActionRole
}

extension PendingRequest.Kind {
    /// Deny · middle · Allow for a permission (Deny · Always · Allow) or a commit
    /// (Skip · Edit · Commit). The one table every surface reads.
    var actions: (deny: RequestAction, middle: RequestAction, allow: RequestAction) {
        switch self {
        case .permission:
            return (
                RequestAction(title: "Deny", key: Theme.Keys.delete, help: "Deny (\(Theme.Keys.delete))", role: .deny),
                RequestAction(title: "Always", key: Theme.Keys.always, help: "Allow and remember (\(Theme.Keys.always))", role: .neutral),
                RequestAction(title: "Allow", key: Theme.Keys.enter, help: "Allow (\(Theme.Keys.enter))", role: .allow)
            )
        case .commit:
            return (
                RequestAction(title: "Skip", key: Theme.Keys.delete, help: "Skip this commit (\(Theme.Keys.delete))", role: .deny),
                RequestAction(title: "Edit", key: Theme.Keys.edit, help: "Ask for a different message (\(Theme.Keys.edit))", role: .neutral),
                RequestAction(title: "Commit", key: Theme.Keys.enter, help: "Commit (\(Theme.Keys.enter))", role: .allow)
            )
        }
    }
}

extension PendingRequest {
    /// Seconds left until the deadline at `date`, never below 0.
    func remaining(at date: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(date))
    }

    /// Share of the request's time left at `date`, 1 → 0.
    func remainingFraction(at date: Date) -> Double {
        remaining(at: date) / max(1, deadline.timeIntervalSince(receivedAt))
    }

    /// "Allow Bash?" (an MCP tool by its own name) or "Commit?".
    var headline: String {
        kind == .commit ? "Commit?" : "Allow \(Format.toolName(tool))?"
    }

    /// The command or path (an MCP tool's server leads it), or the commit subject.
    var summary: String {
        if kind == .commit { return title }
        guard let server = Format.mcpServer(tool) else { return detail }
        return detail.isEmpty ? server : server + Theme.Glyphs.separator + detail
    }
}
