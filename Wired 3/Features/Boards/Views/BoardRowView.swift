//
//  BoardRowView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct BoardRowView: View {
    let board: Board

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "newspaper")
                .foregroundStyle(board.writable ? .primary : .secondary)
            Text(board.name)
            Spacer(minLength: 8)
            UnreadCountBadge(count: board.unreadPostsCount)
        }
    }
}
