//
//  ChatEvent.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 25/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import SwiftUI

public enum ChatEventType {
case say, me, join, leave, event
}

@Observable
@MainActor
final class ChatEvent: Identifiable {

    let id: UUID
    var chat: Chat
    var user: User
    var text: String
    var type: ChatEventType
    var date = Date()

    /// Lazily computed on first access and cached for the lifetime of the event.
    /// `text` is effectively immutable after init, so the cache is always valid.
    /// `@ObservationIgnored` keeps this out of SwiftUI's dependency tracking.
    @ObservationIgnored private var _imageURLCached = false
    @ObservationIgnored private var _cachedPrimaryImageURL: URL? = nil

    var cachedPrimaryHTTPImageURL: URL? {
        if !_imageURLCached {
            _imageURLCached = true
            _cachedPrimaryImageURL = text.detectedHTTPImageURLs().first
        }
        return _cachedPrimaryImageURL
    }

    init(chat: Chat, user: User, type: ChatEventType, text: String) {
        self.id = UUID()
        self.chat = chat
        self.user = user
        self.text = text
        self.type = type
    }
}
