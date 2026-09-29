// KeyboardController.swift
// A local keyDown monitor, installed only while the card or attention state
// is up. Decodes keys into NotchKey and swallows the ones the app used.

import AppKit
import Carbon

@MainActor
final class KeyboardController {
    private var monitor: Any?
    private let handler: (NotchKey) -> Bool

    init(handler: @escaping (NotchKey) -> Bool) {
        self.handler = handler
    }

    var isInstalled: Bool { monitor != nil }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let key = KeyboardController.decode(event) else { return event }
            let used = MainActor.assumeIsolated { () -> Bool in
                self?.handler(key) ?? false
            }
            return used ? nil : event
        })
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    nonisolated static func decode(_ event: NSEvent) -> NotchKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) && Int(event.keyCode) == kVK_ANSI_Comma { return .settings }
        if flags.contains(.command) && Int(event.keyCode) == kVK_ANSI_Q { return .quit }
        if flags.contains(.command) && Int(event.keyCode) == kVK_ANSI_B { return .toggleTree }
        if flags.contains(.command) || flags.contains(.control) { return nil }
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return option ? .teleport : .primary
        case kVK_Delete, kVK_ForwardDelete:
            return .deny
        case kVK_Escape:
            return .escape
        case kVK_Tab:
            return shift ? .previousTab : .nextTab
        case kVK_UpArrow:
            return option ? .hunkUp : .up
        case kVK_DownArrow:
            return option ? .hunkDown : .down
        case kVK_LeftArrow:
            return .left
        case kVK_RightArrow:
            return .right
        case kVK_ANSI_1:
            return .number(1)
        case kVK_ANSI_2:
            return .number(2)
        case kVK_ANSI_3:
            return .number(3)
        case kVK_ANSI_4:
            return .number(4)
        case kVK_ANSI_5:
            return .number(5)
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": return .always
        case "e": return .edit
        case "y": return .copy
        case "d": return .diff
        case "/": return .filter
        case "p": return .markdownMode
        case "w": return .worktree
        case "r": return .repository
        default: return nil
        }
    }
}
