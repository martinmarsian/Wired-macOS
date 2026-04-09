//
//  ThreadRowView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct ThreadRowView: View {
    let thread: BoardThread

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .opacity(thread.isUnreadThread ? 1 : 0)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(thread.subject)
                        .font(.headline)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    UnreadCountBadge(count: thread.unreadPostsCount + thread.unreadReactionCount)
                }

                HStack(spacing: 6) {
                    Text(thread.nick)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !thread.topReactionEmojis.isEmpty {
                        Text(thread.topReactionEmojis.prefix(5).joined())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if thread.replies > 0 {
                        Label("\(thread.replies)", systemImage: "bubble.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(Self.dateFormatter.string(from: thread.lastReplyDate ?? thread.postDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
