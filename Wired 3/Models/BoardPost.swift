//
//  BoardPost.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 01/03/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI
import WiredSwift

/// Lightweight summary of a single emoji reaction on a thread or post.
struct BoardReactionSummary: Identifiable, Equatable {
    let emoji: String
    let count: Int
    /// Whether the current session account has contributed to this reaction.
    let isOwn: Bool

    var id: String { emoji }
}

@Observable
@MainActor
final class BoardPost: Identifiable {
    let id: UUID = UUID()

    var uuid: String
    var threadUUID: String
    var text: String
    var nick: String
    var postDate: Date
    var editDate: Date?
    var icon: Data?
    var isOwn: Bool
    var isUnread: Bool = false
    var isThreadBody: Bool = false
    var reactions: [BoardReactionSummary] = []
    var reactionsLoaded: Bool = false

    init(uuid: String,
         threadUUID: String,
         text: String,
         nick: String,
         postDate: Date,
         icon: Data? = nil,
         isOwn: Bool = false,
         isThreadBody: Bool = false) {
        self.uuid       = uuid
        self.threadUUID = threadUUID
        self.text       = text
        self.nick       = nick
        self.postDate   = postDate
        self.icon       = icon
        self.isOwn      = isOwn
        self.isThreadBody = isThreadBody
    }
}
