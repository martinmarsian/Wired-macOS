//
//  ThreadSortCriterion.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import Swift

public enum ThreadSortCriterion: String, CaseIterable, Identifiable {
    case unread
    case subject
    case nick
    case replies
    case subjectDate
    case lastReplyDate

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .unread: return "Trier par non-lus"
        case .subject: return "Trier par sujets"
        case .nick: return "Trier par pseudo"
        case .replies: return "Trier par reponses"
        case .subjectDate: return "Trier par date du sujet"
        case .lastReplyDate: return "Trier par date de la derniere reponse"
        }
    }
}
