//
//  StoredChatMessage.swift
//  Wired-macOS
//

import Foundation
import SwiftData

@Model
final class StoredChatMessage {
    @Attribute(.unique) var eventID: UUID
    var connectionKey: String
    var chatID: UInt32
    var chatName: String
    var senderNick: String
    var senderUserID: UInt32
    var senderIcon: Data?
    var senderColor: UInt32
    var text: String
    var type: Int
    var date: Date
    var dayKey: String
    var isFromCurrentUser: Bool

    init(
        eventID: UUID,
        connectionKey: String,
        chatID: UInt32,
        chatName: String,
        senderNick: String,
        senderUserID: UInt32,
        senderIcon: Data?,
        senderColor: UInt32,
        text: String,
        type: Int,
        date: Date,
        dayKey: String,
        isFromCurrentUser: Bool
    ) {
        self.eventID = eventID
        self.connectionKey = connectionKey
        self.chatID = chatID
        self.chatName = chatName
        self.senderNick = senderNick
        self.senderUserID = senderUserID
        self.senderIcon = senderIcon
        self.senderColor = senderColor
        self.text = text
        self.type = type
        self.date = date
        self.dayKey = dayKey
        self.isFromCurrentUser = isFromCurrentUser
    }
}
