// RequestActions.swift
// What a pending request offers and says: its actions (Deny · middle · Allow), its
// headline and summary, and the time left before its deadline.

import SwiftUI

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
        case .plan:
            return (
                // "Revise", not "Keep planning": the open card's right wing has room for one short word.
                RequestAction(title: "Revise", key: Theme.Keys.delete, help: "Keep planning: Claude asks what to change (\(Theme.Keys.delete))", role: .deny),
                RequestAction(title: "Auto-accept", key: Theme.Keys.always, help: "Approve and auto-accept edits for this session (\(Theme.Keys.always))", role: .neutral),
                RequestAction(title: "Approve", key: Theme.Keys.enter, help: "Approve the plan (\(Theme.Keys.enter))", role: .allow)
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

    /// "Allow Bash?" (an MCP tool by its own name), "Commit?" or "Plan ready".
    var headline: String {
        switch kind {
        case .permission: return "Allow \(Format.toolName(tool))?"
        case .commit: return "Commit?"
        case .plan: return "Plan ready"
        }
    }

    /// The command or path (an MCP tool's server leads it), the commit subject, or the plan's heading.
    var summary: String {
        if kind == .commit || kind == .plan { return title }
        guard let server = Format.mcpServer(tool) else { return detail }
        return detail.isEmpty ? server : server + Theme.Glyphs.separator + detail
    }
}
