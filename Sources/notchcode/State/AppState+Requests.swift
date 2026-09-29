// AppState+Requests.swift
// Pending requests: the queue, the owner's answers, and the diff inside a request card.

import AppKit
import SwiftUI

/// The one file whose diff is open inside a permission or commit card.
struct RequestDiffTarget: Equatable {
    var requestId: String
    var path: String
}

/// A request card's diff moves by `delta` lines each time `seq` changes (↑↓ while it is open).
struct RequestDiffScroll: Equatable {
    var seq = 0
    var delta = 0
}

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

    func allow(id: String) {
        resolve(id, with: HookReply(id: id, decision: .allow))
    }

    func deny(id: String) {
        resolve(id, with: HookReply(id: id, decision: .deny, reason: "The owner denied this from notchcode."))
    }

    func allowAlways(id: String) {
        resolve(id, with: HookReply(id: id, decision: .allow, always: true))
    }

    /// Commit card "Edit": let Claude know the owner wants a different message.
    func requestCommitEdit(id: String) {
        resolve(id, with: HookReply(
            id: id,
            decision: .deny,
            reason: "The owner wants to change the commit message first. Ask them for the message, then commit again."
        ))
    }

    // MARK: - Pending requests

    func enqueue(_ request: PendingRequest, reply: @escaping ReplyHandler) {
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

        let id = request.id
        let delay = max(0, request.deadline.timeIntervalSinceNow)
        deadlineTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            self?.resolve(id, with: HookReply(id: id, decision: .none), timedOut: true)
        }
    }

    /// Replies exactly once and forgets the request. An answer means Claude moves on; a lapsed
    /// deadline means Claude Code's own terminal prompt now waits, which still needs the owner
    /// for a short while.
    func resolve(_ id: String, with reply: HookReply, timedOut: Bool = false) {
        guard let handler = handlers[id] else { return }
        let sid = dropPending(id)
        handler(reply)
        if let sid {
            if reply.decision != .none {
                clearNeedsYou(sid)
            } else if timedOut, !pending.contains(where: { $0.sessionId == sid }) {
                markNeedsYou(sid)
            }
        }
        afterPendingChange(sessionId: sid)
    }

    /// Forgets a request and its reply handler without replying. Returns its session id.
    @discardableResult
    func dropPending(_ id: String) -> String? {
        guard handlers.removeValue(forKey: id) != nil else { return nil }
        deadlineTasks.removeValue(forKey: id)?.cancel()
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
