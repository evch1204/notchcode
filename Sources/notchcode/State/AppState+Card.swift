// AppState+Card.swift
// Opening and closing the card, the tools under the strip, and the keys the card handles.

import AppKit
import SwiftUI

extension AppState {

    func setHovering(_ value: Bool) {
        if hovering != value { hovering = value }
        // The collapsed tools go away with the hover, and their exit may never report.
        if !value, !isCardOpen { clearToolLabel() }
    }

    /// The mouse entered or left a tool. The first name waits `toolLabelDelay`; once one
    /// shows, moving to the next tool moves it at once. Leaving waits `toolLabelLinger`, so
    /// sliding across the gap between two tools does not blink it.
    func hoverTool(_ tab: CardTab, inside: Bool) {
        if inside {
            toolLabelTask?.cancel()
            if toolLabel != nil {
                setToolLabel(tab)
            } else {
                scheduleToolLabel(tab, after: Theme.Motion.toolLabelDelay)
            }
        } else if toolLabel == tab || toolLabel == nil {
            toolLabelTask?.cancel()
            scheduleToolLabel(nil, after: Theme.Motion.toolLabelLinger)
        }
    }

    /// `⇥` or `1–4` moved the selection: its name shows under it for a moment.
    private func flashToolLabel() {
        toolLabelTask?.cancel()
        setToolLabel(selectedTab)
        scheduleToolLabel(nil, after: Theme.Motion.toolLabelKeyboardHold)
    }

    private func clearToolLabel() {
        toolLabelTask?.cancel()
        setToolLabel(nil)
    }

    private func setToolLabel(_ tab: CardTab?) {
        if toolLabel != tab { toolLabel = tab }
    }

    private func scheduleToolLabel(_ tab: CardTab?, after seconds: Double) {
        toolLabelTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            self?.setToolLabel(tab)
        }
    }

    func openCard(tab: CardTab? = nil) {
        if let req = currentPending {
            cardOpenedForRequest = true
            focusedSessionId = req.sessionId
        } else if let tab {
            questionShown = false
            selectedTab = tab
        }
        if focusedSessionId == nil || session(id: focusedSessionId ?? "") == nil {
            focusedSessionId = primarySession?.id
        }
        if let id = focusedSessionId, let index = orderedSessions.firstIndex(where: { $0.id == id }) {
            sessionCursor = index
        }
        if selectedTab == .files { loadRepoTree() }
        isCardOpen = true
        gitCardOpened()
        skipFocusReturn = false
        clearToolLabel()
        recomputeUsage()
        refresh()
    }

    func closeCard() {
        guard isCardOpen else { return }
        isCardOpen = false
        cardOpenedForRequest = false
        questionShown = false
        clearToolLabel()
        if !CardTab.browsable.contains(selectedTab) { selectedTab = .sessions }
        fileFilterFocused = false
        requestDiff = nil
        gitCardClosed()
        refresh()
    }

    /// Settings is a page inside the card. A pending request still takes the card first.
    func openSettings() {
        guard currentPending == nil else { return }
        if selectedTab != .settings {
            tabBeforeSettings = CardTab.browsable.contains(selectedTab) ? selectedTab : .sessions
        }
        if isCardOpen {
            selectTab(.settings)
        } else {
            openCard(tab: .settings)
        }
    }

    func closeSettings() {
        guard selectedTab == .settings else { return }
        selectTab(tabBeforeSettings)
    }

    /// Row click or ⏎ in the Sessions tab: show that session's changes.
    func selectSession(_ session: Session) {
        focusedSessionId = session.id
        if let index = orderedSessions.firstIndex(where: { $0.id == session.id }) {
            sessionCursor = index
        }
        rowCursor = 0
        selectTab(.changes)
    }

    /// Read once by AppDelegate when the card closes.
    func takeSkipFocusReturn() -> Bool {
        defer { skipFocusReturn = false }
        return skipFocusReturn
    }

    /// Shows a short inline hint for a couple of seconds.
    func flash(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Timing.hintDuration))
            if Task.isCancelled { return }
            self?.hint = nil
        }
    }

    func toggleFromNotchTap() {
        if isCardOpen {
            closeCard()
        } else if currentPending != nil {
            openCard()
        } else if question != nil {
            openQuestion()
        } else {
            // From the notch the card always lands on Sessions; only a blocking request (above) differs.
            openCard(tab: .sessions)
        }
    }

    /// Opens the card on the question preview (it can only be answered in the terminal).
    func openQuestion() {
        guard let question else { return }
        focusedSessionId = question.sessionId
        questionShown = true
        openCard()
    }

    func selectTab(_ tab: CardTab) {
        questionShown = false
        if tab != selectedTab {
            rowCursor = 0
            let order = CardTab.browsable
            if let from = order.firstIndex(of: selectedTab), let to = order.firstIndex(of: tab) {
                tabMovedForward = to > from
            } else {
                tabMovedForward = true
            }
        }
        selectedTab = tab
        if tab != .files { fileFilterFocused = false }
        if tab == .files { loadRepoTree() }
        if tab == .git { gitToolShown() }
        refresh()
    }

    /// ⌘Q while the card is open, or the Quit button in Settings. Pending requests are left
    /// unanswered on purpose: their hooks time out and the terminal prompt takes over.
    func quit() {
        NSApp.terminate(nil)
    }

    /// Returns true when the key was used.
    func handleKey(_ key: NotchKey) -> Bool {
        guard mode == .card || mode == .attention else { return false }
        if key == .quit { quit(); return true }

        let filesOpen = isCardOpen && isShowingTool(.files)
        if key == .escape, filesOpen, fileFilterFocused || !fileFilter.isEmpty {
            // Esc clears the filter first; a second esc closes the card.
            withAnimation(Theme.Motion.filterRows) { fileFilter = "" }
            fileFilterFocused = false
            return true
        }
        if filesOpen && fileFilterFocused {
            // Typing goes to the filter field; only the tree keys and teleport stay with the card.
            switch key {
            case .up, .down, .primary, .teleport: break
            default: return false
            }
        }

        let gitShown = isCardOpen && isShowingTool(.git)
        if gitShown, gitPanel.pickerOpen, gitPanel.filterFocused, !gitPanel.repoMenuOpen {
            // Typing goes to the branch filter; only the picker's keys stay with the card.
            switch key {
            case .up, .down, .primary, .escape: break
            default: return false
            }
        }
        // Esc in the Git tool closes the repository dropdown, then clears the branch filter,
        // then leaves the picker, then cancels the push confirm, before it closes the card.
        if key == .escape, gitShown, gitEscape() { return true }
        if key == .escape {
            guard isCardOpen else { return false }
            if let req = currentPending, requestDiffPath(for: req) != nil {
                // Esc closes the diff first, then the card.
                closeRequestDiff()
            } else if case .settings = cardContent {
                closeSettings()
            } else {
                closeCard()
            }
            return true
        }
        if key == .settings {
            if isCardOpen && selectedTab == .settings {
                closeSettings()
            } else {
                openSettings()
            }
            return true
        }
        if key == .teleport {
            let ordered = orderedSessions
            if isCardOpen, isShowingTool(.sessions), ordered.indices.contains(sessionCursor) {
                teleport(session: ordered[sessionCursor])
            } else {
                teleport(session: focusedSession)
            }
            return true
        }

        if let req = currentPending {
            // `answer` swallows a press that comes before `answerKeysAllowedAt`.
            switch key {
            case .primary: answer(.allow, to: req)
            case .deny: answer(.deny, to: req)
            case .always:
                guard req.kind == .permission else { return false }
                answer(.always, to: req)
            case .edit:
                guard req.kind == .commit else { return false }
                answer(.edit, to: req)
            case .diff:
                return toggleRequestDiffAtCursor(req)
            case .up, .down:
                guard isCardOpen else { return false }
                let step = key == .up ? -1 : 1
                if requestDiffPath(for: req) != nil {
                    requestDiffScroll = RequestDiffScroll(
                        seq: requestDiffScroll.seq + 1,
                        delta: step * Theme.Limits.requestDiffScrollLines
                    )
                } else if req.kind == .commit, !req.files.isEmpty {
                    let shown = min(req.files.count, Theme.Limits.commitMaxFileRows)
                    requestRowCursor = max(0, min(shown - 1, requestRowCursor + step))
                } else {
                    return false
                }
            default:
                return false
            }
            return true
        }

        guard isCardOpen else { return false }

        if showingQuestion {
            switch key {
            case .primary:
                teleport(session: question.flatMap { session(id: $0.sessionId) })
                return true
            case .number:
                return true // options are read-only; swallow so nothing else reacts
            case .nextTab:
                cycleTab(by: 1)
                return true
            case .previousTab:
                cycleTab(by: -1)
                return true
            default:
                return false // the tool's keys wait until a tool shows
            }
        }

        if selectedTab == .files, let used = handleFilesKey(key) { return used }
        if selectedTab == .git, let used = handleGitKey(key) { return used }

        let rows = selectedTab == .changes ? changesRows : []

        switch key {
        case .number(let n):
            guard n >= 1 && n <= CardTab.browsable.count else { return false }
            selectTab(CardTab.browsable[n - 1])
            flashToolLabel()
        case .nextTab:
            cycleTab(by: 1)
        case .previousTab:
            cycleTab(by: -1)
        case .up:
            if selectedTab == .sessions, !sessions.isEmpty {
                sessionCursor = max(0, sessionCursor - 1)
            } else if !rows.isEmpty {
                rowCursor = max(0, min(rows.count - 1, rowCursor - 1))
            } else {
                return false
            }
        case .down:
            if selectedTab == .sessions, !sessions.isEmpty {
                sessionCursor = min(sessions.count - 1, sessionCursor + 1)
            } else if !rows.isEmpty {
                rowCursor = min(rows.count - 1, rowCursor + 1)
            } else {
                return false
            }
        case .primary:
            if selectedTab == .sessions {
                let ordered = orderedSessions
                guard ordered.indices.contains(sessionCursor) else { return false }
                selectSession(ordered[sessionCursor])
            } else if rows.indices.contains(rowCursor) {
                switch rows[rowCursor] {
                case .turn(let turn):
                    guard !turn.files.isEmpty else { return false }
                    withAnimation(Theme.Motion.disclosure) { toggleTurn(turn.id) }
                case .file(let item):
                    guard !Self.diffLines(item.file).isEmpty else { return false }
                    withAnimation(Theme.Motion.tap) { toggleDiff(item.key) }
                }
            } else {
                return false
            }
        case .copy:
            guard selectedTab == .changes else { return false }
            return copyCursorLocation()
        default:
            return false
        }
        return true
    }

    private func cycleTab(by step: Int) {
        let tabs = CardTab.browsable
        // From Settings or the question, ⇥ lands on the first tool and ⇧⇥ on the last.
        let onTool: Bool
        if case .tool = cardContent { onTool = true } else { onTool = false }
        let current = (onTool ? tabs.firstIndex(of: selectedTab) : nil) ?? (step > 0 ? -1 : tabs.count)
        let next = ((current + step) % tabs.count + tabs.count) % tabs.count
        selectTab(tabs[next])
        flashToolLabel()
    }
}
