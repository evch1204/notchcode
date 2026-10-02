// AppDelegate.swift
// Builds the panel, starts the socket, registers ⌥space (when the owner wants
// it), opens on hover (when the owner wants it), and keeps the panel's mouse
// and key behaviour in step with the notch state.

import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var panel: NotchPanel?
    private var server: SocketServer?
    private var hotKey: HotKey?
    private var keyboard: KeyboardController?
    private var demo: DemoScript?
    private var watcher: TranscriptWatcher?
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var lastMode: NotchMode = .closed
    private var previousApp: NSRunningApplication?
    private var mouseInside = false
    private var hoverOpenWork: DispatchWorkItem?
    private var hoverCloseWork: DispatchWorkItem?
    /// Mouse over the shape right now, and the pending 250 ms dwell before the rim lights.
    private var rimInside = false
    private var rimWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = self.state

        let panel = NotchPanel(rootView: NotchRootView(state: state))
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()

        let server = SocketServer(sink: state)
        do {
            try server.start()
        } catch {
            // The notch still works without the socket (demo, UI); hooks just get no reply.
        }
        self.server = server

        updateHotKey(enabled: state.prefs.hotkeyEnabled)

        keyboard = KeyboardController { [weak self] key in
            self?.state.handleKey(key) ?? false
        }

        installObservers(state)
        syncPanel()

        if CommandLine.arguments.contains("--demo") {
            let script = DemoScript(state: state)
            demo = script
            script.start()
        } else {
            // Sessions from the last hours, read straight from ~/.claude/projects.
            let watcher = TranscriptWatcher(sink: state)
            self.watcher = watcher
            watcher.start()
            // Plan limits from Claude Code's usage cache, refreshed by `claude -p /usage`.
            state.startPlanUsage()
        }
        runDebugKeys()
    }

    /// `--debug-keys open,c,1.5,esc`: after three seconds, each name in turn with 1.2 s
    /// between them: "open" opens the card on the Git tool ("open:changes" on another), a number sleeps that many
    /// seconds, anything else is a key (esc, enter, cmdenter, cmdb, space, up, down, c, p,
    /// u, w, r, /, y, 1 to 5). "snap:<name>" renders the panel's view (no screen capture, so no
    /// screen-recording permission) to Application Support/notchcode/snapshots/<name>.png.
    /// For screenshots of the tool's states while nobody is at the keys.
    private func runDebugKeys() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--debug-keys"), index + 1 < args.count else { return }
        let names = args[index + 1].split(separator: ",").map(String.init)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            for name in names {
                guard let self else { return }
                if let seconds = Double(name) {
                    try? await Task.sleep(for: .seconds(seconds))
                    continue
                }
                debugLog("debug key \(name)")
                if name == "open" {
                    self.state.openCard(tab: .git)
                } else if name.hasPrefix("open:"), let tab = Self.debugTab(String(name.dropFirst("open:".count))) {
                    self.state.openCard(tab: tab)
                } else if name.hasPrefix("snap:") {
                    self.snapshot(String(name.dropFirst("snap:".count)))
                } else if let key = Self.debugKey(name) {
                    _ = self.state.handleKey(key)
                }
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
    }

    /// Renders the panel's content view at its window's backing scale into a PNG.
    private func snapshot(_ name: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = NotchcodePaths.supportDirectory.appendingPathComponent("snapshots", isDirectory: true)
        let url = folder.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try data.write(to: url)
            debugLog("snapshot \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh) scale=\(view.window?.backingScaleFactor ?? 0)")
        } catch {
            debugLog("snapshot failed \(error)")
        }
    }

    /// "open:changes" and the other tools by their lowercase names.
    private static func debugTab(_ name: String) -> CardTab? {
        CardTab.browsable.first { $0.label.lowercased() == name }
    }

    private static func debugKey(_ name: String) -> NotchKey? {
        switch name {
        case "esc": return .escape
        case "enter": return .primary
        case "cmdenter": return .submit
        case "cmdb": return .toggleTree
        case "space": return .toggle
        case "up": return .up
        case "down": return .down
        case "c": return .commit
        case "p": return .markdownMode
        case "u": return .undo
        case "w": return .worktree
        case "r": return .repository
        case "/": return .filter
        case "y": return .copy
        case "1", "2", "3", "4", "5": return .number(Int(name)!)
        default: return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        watcher?.stop()
        keyboard?.remove()
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
    }

    // MARK: - Observers

    private func updateHotKey(enabled: Bool) {
        if !enabled {
            hotKey = nil
            return
        }
        guard hotKey == nil else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            MainActor.assumeIsolated {
                self?.state.toggleFromNotchTap()
            }
        }
    }

    private func installObservers(_ state: AppState) {
        state.$prefs
            .map(\.hotkeyEnabled)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    self?.updateHotKey(enabled: enabled)
                }
            }
            .store(in: &cancellables)

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncPanel()
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reposition()
            }
        }

        // Mouse pass-through: the panel takes the mouse only over the drawn shape.
        let globalMove = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMousePassthrough()
            }
        })
        let localMove = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateMousePassthrough()
            }
            return event
        })
        // A click in another app closes the card.
        let globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clickedElsewhere()
            }
        })
        for monitor in [globalMove, localMove, globalClick] {
            if let monitor { eventMonitors.append(monitor) }
        }
    }

    // MARK: - Panel state

    private func reposition() {
        guard let panel else { return }
        // No screen (lid closed, display unplugged): keep the last frame until one returns.
        guard let geometry = NotchGeometry.current() else { return }
        state.setNotch(width: geometry.notchWidth, height: geometry.notchHeight)
        let frame = NSRect(
            x: geometry.notchFrame.midX - Theme.Size.panelWidth / 2,
            y: geometry.screen.frame.maxY - Theme.Size.panelHeight,
            width: Theme.Size.panelWidth,
            height: Theme.Size.panelHeight
        )
        panel.setFrame(frame, display: true)
        let hosting = panel.contentView?.subviews.first
        debugLog("panel=\(panel.frame) screen=\(geometry.screen.frame) notch=\(geometry.notchFrame) contentSafe=\(String(describing: panel.contentView?.safeAreaInsets)) hostingSafe=\(String(describing: hosting?.safeAreaInsets)) hostingFrame=\(String(describing: hosting?.frame)) scale=\(geometry.screen.backingScaleFactor)")
        syncPanel()
    }

    private func syncPanel() {
        guard let panel else { return }
        let mode = state.mode
        panel.container.interactiveSize = state.layout.outerSize(for: mode, cardHeight: state.cardHeight)
        updateMousePassthrough()

        if mode != lastMode {
            lastMode = mode
            updateKeyFocus(for: mode)
            if mode == .card || mode == .attention {
                keyboard?.install()
            } else {
                keyboard?.remove()
            }
        }
    }

    private func updateMousePassthrough() {
        guard let panel else { return }
        let inside = panel.interactiveScreenRect().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        updateRim(inside: inside)
        updateHover(inside: inside)
    }

    // MARK: - Hover rim

    /// After the mouse rests on the shape for `Theme.Motion.rimDelay`, `hovering` turns on;
    /// leaving turns it off at once. Hover-to-open owners skip it: the same dwell opens the
    /// card, and a rim fading in while the shape starts growing (then vanishing as the mode
    /// leaves closed) read as a second, competing animation.
    private func updateRim(inside: Bool) {
        guard inside != rimInside else { return }
        rimInside = inside
        rimWork?.cancel()
        rimWork = nil
        if inside {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.rimInside else { return }
                    self.rimWork = nil
                    guard self.state.prefs.openGesture != .hover else { return }
                    self.state.setHovering(true)
                }
            }
            rimWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.rimDelay, execute: work)
        } else {
            state.setHovering(false)
        }
    }

    // MARK: - Hover to open

    /// Open after the mouse rests on the shape; close after it has left the card.
    private func updateHover(inside: Bool) {
        guard state.prefs.openGesture == .hover else {
            cancelHover()
            mouseInside = false
            return
        }
        let changed = inside != mouseInside
        mouseInside = inside
        let open = state.mode == .card

        if inside {
            hoverCloseWork?.cancel()
            hoverCloseWork = nil
            // The attention row answers in one press; opening under the pointer on its way to
            // Allow would move the button away. Click row 1 (or ⌥ space) opens it instead.
            guard !open, state.mode != .attention, changed || hoverOpenWork == nil else { return }
            hoverOpenWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let state = self.state
                    self.hoverOpenWork = nil
                    guard self.mouseInside, state.mode != .card, state.mode != .attention,
                          state.prefs.openGesture == .hover else { return }
                    state.toggleFromNotchTap()
                }
            }
            hoverOpenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.hoverOpenDelay, execute: work)
        } else {
            hoverOpenWork?.cancel()
            hoverOpenWork = nil
            guard open, hoverCloseWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let state = self.state
                    self.hoverCloseWork = nil
                    guard !self.mouseInside, state.mode == .card, state.prefs.openGesture == .hover else { return }
                    state.closeCard()
                }
            }
            hoverCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Timing.hoverCloseDelay, execute: work)
        }
    }

    private func cancelHover() {
        hoverOpenWork?.cancel()
        hoverOpenWork = nil
        hoverCloseWork?.cancel()
        hoverCloseWork = nil
    }

    /// The panel takes key focus only while the card is open, so return, delete
    /// and friends work there; otherwise focus stays in the terminal.
    private func updateKeyFocus(for mode: NotchMode) {
        guard let panel else { return }
        if mode == .card {
            guard !panel.allowsKey else { return }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp = front
            }
            panel.allowsKey = true
            panel.makeKeyAndOrderFront(nil)
        } else if panel.allowsKey {
            panel.allowsKey = false
            // Teleport already brought a terminal forward; do not steal focus back from it.
            if state.takeSkipFocusReturn() == true { previousApp = nil }
            if panel.isKeyWindow {
                // Give key status back without hiding the notch.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
            previousApp?.activate()
            previousApp = nil
        }
    }

    private func clickedElsewhere() {
        guard state.mode == .card else { return }
        state.closeCard()
    }
}
