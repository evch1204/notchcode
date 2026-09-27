// FilesTab.swift
// Files the selected session touched today, grouped by directory. Each row has
// its ±counts and opens to the same diff as Changes. "y" copies path:line of
// the first changed line of the row under the cursor.

import SwiftUI

@MainActor
struct FilesTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        let sid = state.focusedSession?.id
        let files = state.filesToday(for: sid)
        if state.turns(for: sid).isEmpty {
            EmptyNote(text: "Nothing changed yet in this session")
        } else if files.isEmpty {
            EmptyNote(text: "No files changed today in this session")
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.Size.spaceXS) {
                        ForEach(groups(files), id: \.directory) { group in
                            Text(group.directory.isEmpty ? "./" : group.directory)
                                .font(Theme.Fonts.monoSmall)
                                .foregroundStyle(Theme.Colors.inkTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.top, Theme.Size.groupHeaderTopPadding)
                                .padding(.leading, Theme.Size.rowHPadding)
                            ForEach(group.files) { file in
                                FileDiffRow(state: state, item: DiffRowItem(key: AppState.filesRowKey(file), file: file))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.rowCursor) { _, _ in
                    guard let key = state.cursorRowKey else { return }
                    withAnimation(Theme.Motion.tap) { proxy.scrollTo(key) }
                }
            }
        }
    }

    private struct Group {
        let directory: String
        var files: [FileChange]
    }

    /// `filesToday` is already sorted by directory, so groups are runs of equal directories.
    private func groups(_ files: [FileChange]) -> [Group] {
        var result: [Group] = []
        for file in files {
            let dir = Format.directory(file.path)
            if result.last?.directory == dir {
                result[result.count - 1].files.append(file)
            } else {
                result.append(Group(directory: dir, files: [file]))
            }
        }
        return result
    }
}
