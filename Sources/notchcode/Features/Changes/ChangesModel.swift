// ChangesModel.swift
// The Changes tool's value types: a file chip's key, the timeline's blocks, the cursor's
// stops, and the tool's view choices that AppState keeps as one value (`changesTool`).

import Foundation

/// A file chip: the file `path` as the turn `turnId` changed it.
struct ChangesChipKey: Hashable {
    var turnId: String
    var path: String
}

/// One block of the timeline, newest first.
enum ChangesBlock: Identifiable, Equatable {
    /// A turn with files, or the live turn. `number` counts from the session's first turn.
    case entry(TranscriptTurn, number: Int, live: Bool)
    /// A run of turns without files, newest first; keyed by its newest turn's id.
    case quiet(id: String, turns: [TranscriptTurn])

    var id: String {
        switch self {
        case .entry(let turn, _, _): return "e|" + turn.id
        case .quiet(let id, _): return "g|" + id
        }
    }
}

/// A stop of the Changes cursor (`rowCursor` indexes `changesCursorItems`).
enum ChangesItem: Identifiable, Equatable {
    /// The live turn while it has no edits: the cursor rests on it.
    case live(turnId: String)
    case chip(ChangesChipKey)
    /// A quiet group's row.
    case group(id: String)
    /// One turn of an unfolded quiet group.
    case quiet(turnId: String)

    var id: String {
        switch self {
        case .live(let id): return "l|" + id
        case .chip(let key): return AppState.changesChipID(key)
        case .group(let id): return "g|" + id
        case .quiet(let id): return "q|" + id
        }
    }
}

/// The Changes tool's view choices. All reset when the focused session changes.
struct ChangesToolState: Equatable {
    /// The chip whose diff the pane shows (it stays after esc closes the pane).
    var selection: ChangesChipKey?
    /// The diff pane is open beside the timeline.
    var paneOpen = false
    /// `/`: only the turns with edits (and the live turn); quiet groups hide.
    var editsOnly = false
    /// Quiet groups unfolded into one row per turn, by the group's id.
    var unfoldedGroups: Set<String> = []
    /// ⌘B while the pane shows: the timeline column is hidden and the pane takes the width.
    var columnHidden = false
}
