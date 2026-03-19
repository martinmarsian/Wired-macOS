//
//  Chat.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 25/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import SwiftUI

@Observable
@MainActor
final class Chat: Identifiable {
    let id: UInt32
    var name: String
    var isPrivate: Bool
    var topic: Topic?
    var joined = false
    
    var users : [User] = []
    var messages : [ChatEvent] = []
    
    var unreadMessagesCount : Int = 0
    
    init(id: UInt32, name: String, isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
    }
}

extension ChatEvent {
    func matchesSearch(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmedChatSearchQuery
        guard !query.isEmpty else { return true }

        return user.nick.localizedStandardContains(query)
            || text.localizedStandardContains(query)
    }

    var searchPreviewText: String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            return trimmedText
        }

        return user.nick
    }
}

extension Chat {
    func matchesSearch(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmedChatSearchQuery
        guard !query.isEmpty else { return true }

        if name.localizedStandardContains(query) {
            return true
        }

        if let topic {
            if topic.topic.localizedStandardContains(query) || topic.nick.localizedStandardContains(query) {
                return true
            }
        }

        return messages.contains { $0.matchesSearch(query) }
    }

    func filteredMessages(matching rawQuery: String) -> [ChatEvent] {
        let query = rawQuery.trimmedChatSearchQuery
        guard !query.isEmpty else { return messages }

        return messages.filter { $0.matchesSearch(query) }
    }

    func previewText(matching rawQuery: String) -> String? {
        let query = rawQuery.trimmedChatSearchQuery
        guard !query.isEmpty else {
            return messages.last?.searchPreviewText ?? topic?.topic
        }

        if let matchingMessage = messages.last(where: { $0.matchesSearch(query) }) {
            return matchingMessage.searchPreviewText
        }

        if let topic, topic.topic.localizedStandardContains(query) || topic.nick.localizedStandardContains(query) {
            let trimmedTopic = topic.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTopic.isEmpty ? topic.nick : trimmedTopic
        }

        return nil
    }
}

private extension String {
    var trimmedChatSearchQuery: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
