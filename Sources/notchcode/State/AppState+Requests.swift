// AppState+Requests.swift
// Pending requests: the queue, the owner's answers, and the diff inside a request card.

import AppKit
import SwiftUI

/// The one file whose diff is open inside a permission or commit card.
struct RequestDiffTarget: Equatable {
    var requestId: String
    var path: String
}

/// A request card's box moves by `delta` lines (a diff) or blocks (a plan) each time `seq`
/// changes (↑↓ while it is open).
struct RequestDiffScroll: Equatable {
    var seq = 0
    var delta = 0
}

/// The owner's answer to a request: Allow (Commit), Deny (Skip), Always, or Edit.
enum RequestAnswer { case allow, deny, always, edit }

extension AppState {

    // MARK: - Request card diff

    /// The path whose diff is open in `request`'s card, if it is still one of its files.
    func requestDiffPath(for request: PendingRequest) -> String? {
        guard let target = requestDiff, target.requestId == request.id,
              request.files.contains(where: { $0.path == target.path }) else { return nil }
        return target.path
    }

    /// Opens `path`'s diff in the current request card, or closes it when it is the open one.
    /// The card grows (or shrinks) with the shape's height spring.
    func toggleRequestDiff(path: String) {
        guard let req = currentPending,
              let file = req.files.first(where: { $0.path == path }),
              !Self.diffLines(file).isEmpty else { return }
        if let index = req.files.firstIndex(where: { $0.path == path }) { requestRowCursor = index }
        let opening = requestDiffPath(for: req) != path
        withAnimation(Theme.Motion.requestDiff(expanding: opening && requestDiffPath(for: req) == nil)) {
            requestDiff = opening ? RequestDiffTarget(requestId: req.id, path: path) : nil
        }
    }

    func closeRequestDiff() {
        guard requestDiff != nil else { return }
        withAnimation(Theme.Motion.requestDiff(expanding: false)) { requestDiff = nil }
    }

    /// "D": the permission card's file, or the commit card's file under the cursor.
    func toggleRequestDiffAtCursor(_ req: PendingRequest) -> Bool {
        let files = req.files
        guard !files.isEmpty else { return false }
        if let open = requestDiffPath(for: req) {
            toggleRequestDiff(path: open)
            return true
        }
        let index = req.kind == .commit ? max(0, min(files.count - 1, requestRowCursor)) : 0
        guard !Self.diffLines(files[index]).isEmpty else { return false }
        if !isCardOpen { openCard() }
        toggleRequestDiff(path: files[index].path)
        return true
    }

    // MARK: - Owner actions

    /// Every answer, key or click, comes through here. None counts before
    /// `answerKeysAllowedAt`: a press meant for the terminal, or a click as the card slides
    /// in under the pointer, must not answer a request the owner has not seen.
    func answer(_ kind: RequestAnswer, to req: PendingRequest) {
        guard Date() >= answerKeysAllowedAt else { return }
        switch kind {
        case .allow: allow(id: req.id)
        case .deny where req.kind == .plan: revisePlan(id: req.id)
        case .deny: deny(id: req.id)
        case .always where req.kind == .plan: approveAcceptingEdits(id: req.id)
        case .always: allowAlways(id: req.id)
        case .edit: requestCommitEdit(id: req.id)
        }
    }

    private func allow(id: String) {
        resolve(id, with: HookReply(id: id, decision: .allow))
    }

    private func deny(id: String) {
        resolve(id, with: HookReply(id: id, decision: .deny, reason: "The owner denied this from notchcode."))
    }

    /// A plan sent back stays in plan mode: Claude asks in the terminal what to change.
    private func revisePlan(id: String) {
        resolve(id, with: HookReply(
            id: id, decision: .deny,
            reason: "The owner read the plan in notchcode and wants changes. Ask them what to change, then plan again."
        ))
    }

    private func allowAlways(id: String) {
        resolve(id, with: HookReply(id: id, decision: .allow, always: true))
    }

    /// Plan "Auto-accept": approve, and the session accepts edits from now on.
    private func approveAcceptingEdits(id: String) {
        let acceptEdits: JSONValue = .object([
            "type": .string("setMode"),
            "mode": .string("acceptEdits"),
            "destination": .string("session"),
        ])
        resolve(id, with: HookReply(id: id, decision: .allow, always: true, updatedPermissions: .array([acceptEdits])))
    }

    /// Commit card "Edit": let Claude know the owner wants a different message.
    private func requestCommitEdit(id: String) {
        resolve(id, with: HookReply(
            id: id,
            decision: .deny,
            reason: "The owner wants to change the commit message first. Ask them for the message, then commit again."
        ))
    }

    // MARK: - Pending requests

    func enqueue(_ request: PendingRequest, reply: @escaping ReplyHandler) {
        // The plugin and Connect both installed: one tool call arrives twice. Keep the first;
        // the second hook falls back to Claude Code, which the first answer settles.
        if let toolUseId = request.toolUseId,
           pending.contains(where: { $0.sessionId == request.sessionId && $0.toolUseId == toolUseId && $0.id != request.id }) {
            _ = reply(HookReply(id: request.id, decision: .none))
            return
        }
        if handlers[request.id] != nil {
            // Same id twice: answer the old one so it is never left hanging.
            resolve(request.id, with: HookReply(id: request.id, decision: .none))
        }
        handlers[request.id] = reply
        pending.append(request)
        if pending.count == 1 { requestRowCursor = 0 }
        if prefs.systemNotifications {
            SystemNotifier.post(
                title: request.headline,
                subtitle: session(id: request.sessionId)?.displayFull,
                body: request.summary,
                id: request.id
            )
        }
        // The deadline is the transport's: it replies "none" and calls `timedOut(requestId:)`.
    }

    /// Replies exactly once and forgets the request. An answer means Claude moves on.
    /// A press that lands after the transport's deadline reached no one: the terminal still
    /// asks, so the session is marked the timed-out way and the card says so.
    func resolve(_ id: String, with reply: HookReply) {
        guard let handler = handlers[id] else { return }
        let sid = dropPending(id)
        let delivered = handler(reply)
        if let sid {
            if !delivered { unanswered(sid) }
            else if reply.decision != .none { clearNeedsYou(sid) }
        }
        afterPendingChange(sessionId: sid)
        if !delivered && reply.decision != .none { flash("Too late: the terminal asks") }
    }

    /// Forgets a request and its reply handler without replying. Returns its session id.
    @discardableResult
    func dropPending(_ id: String) -> String? {
        guard handlers.removeValue(forKey: id) != nil else { return nil }
        let sid = pending.first(where: { $0.id == id })?.sessionId
        pending.removeAll { $0.id == id }
        SystemNotifier.remove(id: id)
        return sid
    }

    /// State and card follow-up after a request left the queue.
    func afterPendingChange(sessionId sid: String?) {
        if let sid { settle(sid) }
        if requestDiff != nil, requestDiff?.requestId != currentPending?.id {
            requestDiff = nil
            requestRowCursor = 0
        }
        if pending.isEmpty && isCardOpen && cardOpenedForRequest {
            closeCard()
            return
        }
        refresh()
    }
}
