//
//  BoardSearchResultRowView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct BoardSearchResultRowView: View {
    @Environment(ConnectionRuntime.self) private var runtime
    let result: BoardSearchResult

    private var thread: BoardThread? {
        runtime.thread(boardPath: result.boardPath, uuid: result.threadUUID)
        ?? runtime.thread(uuid: result.threadUUID)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .opacity(thread?.isUnreadThread == true ? 1 : 0)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(result.subject)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer(minLength: 6)

                    UnreadCountBadge(count: (thread?.unreadPostsCount ?? 0) + (thread?.unreadReactionCount ?? 0))
                }

                Text(result.snippet.isEmpty ? result.subject : result.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(result.boardPath)
                    Text(thread?.nick ?? result.nick)

                    Spacer()

                    if let thread, thread.replies > 0 {
                        Label("\(thread.replies)", systemImage: "bubble.right")
                    }

                    Text(PostRowView.dateString(thread?.lastReplyDate ?? result.editDate ?? result.postDate))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
