//
//  PermissionLevel.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import Swift

public enum PermissionLevel: String, CaseIterable, Identifiable {
    case none
    case readWrite
    case readOnly
    case writeOnly

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Aucun acces"
        case .readWrite: return "Lecture et ecriture"
        case .readOnly: return "Lecture seulement"
        case .writeOnly: return "Ecriture seulement"
        }
    }

    var read: Bool {
        switch self {
        case .none: return false
        case .readWrite, .readOnly: return true
        case .writeOnly: return false
        }
    }

    var write: Bool {
        switch self {
        case .readWrite, .writeOnly: return true
        case .none, .readOnly: return false
        }
    }

    static func from(read: Bool, write: Bool) -> PermissionLevel {
        switch (read, write) {
        case (false, false): return .none
        case (true, true): return .readWrite
        case (true, false): return .readOnly
        case (false, true): return .writeOnly
        }
    }
}
