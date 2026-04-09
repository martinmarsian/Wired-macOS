//
//  FileItem.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 12/01/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import Foundation
import WiredSwift

enum FileType: UInt32, CustomStringConvertible {
    case file       = 0
    case directory  = 1
    case uploads    = 2
    case dropbox    = 3
    case sync       = 4

    var description: String {
        switch self {
        case .file:
            "File"
        case .directory:
            "Directory"
        case .uploads:
            "Uploads"
        case .dropbox:
            "Drop Box"
        case .sync:
            "Sync"
        }
    }

    var isDirectoryLike: Bool {
        self == .directory || self == .uploads || self == .dropbox || self == .sync
    }

    var isManagedAccessType: Bool {
        self == .dropbox || self == .sync
    }
}

enum SyncModeValue: String, CaseIterable, Identifiable {
    case disabled = "disabled"
    case serverToClient = "server_to_client"
    case clientToServer = "client_to_server"
    case bidirectional = "bidirectional"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .serverToClient:
            return "server_to_client"
        case .clientToServer:
            return "client_to_server"
        case .bidirectional:
            return "bidirectional"
        }
    }
}

public struct FileItem: Identifiable, Hashable {
    public let id = UUID()
    var name: String = ""
    var path: String = ""

    var type: FileType = .file
    var children: [FileItem]?
    var directoryCount: Int = 0
    var hasDirectoryCount = false

    var dataSize: UInt64 = 0
    var rsrcSize: UInt64 = 0
    var creationDate: Date?
    var modificationDate: Date?
    var comment: String = ""
    var owner: String = ""
    var group: String = ""
    var ownerRead = false
    var ownerWrite = false
    var groupRead = false
    var groupWrite = false
    var everyoneRead = false
    var everyoneWrite = false
    var readable = false
    var writable = false
    var syncUserMode: SyncModeValue = .disabled
    var syncGroupMode: SyncModeValue = .disabled
    var syncEveryoneMode: SyncModeValue = .disabled
    var syncEffectiveMode: SyncModeValue = .disabled
    var syncMaxFileSizeBytes: UInt64 = 0
    var syncMaxTreeSizeBytes: UInt64 = 0
    var syncExcludePatterns: String = ""
    var uploadDataSize: UInt64 = 0
    var uploadRsrcSize: UInt64 = 0
    var dataTransferred: UInt64 = 0
    var rsrcTransferred: UInt64 = 0

    var connection: AsyncConnection?

    init(_ name: String, path: String, type: FileType = .file) {
        self.name = name
        self.path = path
        self.type = type
    }

    init(_ message: P7Message, connection: AsyncConnection) {
        self.connection = connection

        if let p = message.string(forField: "wired.file.path") {
            self.path = p
            self.name = self.path.lastPathComponent
        }
        if let t = message.uint32(forField: "wired.file.type") {
            self.type = FileType(rawValue: t) ?? .file
        }
        if let s = message.uint64(forField: "wired.file.data_size") {
            self.dataSize = s
        }
        if let s = message.uint64(forField: "wired.file.rsrc_size") {
            self.rsrcSize = s
        }
        if let s = message.uint32(forField: "wired.file.directory_count") {
            self.directoryCount = Int(s)
            self.hasDirectoryCount = true
        }
        if let date = message.date(forField: "wired.file.creation_time") {
            self.creationDate = date
        }
        if let date = message.date(forField: "wired.file.modification_time") {
            self.modificationDate = date
        }
        if let value = message.string(forField: "wired.file.comment") {
            self.comment = value
        }
        if let value = message.string(forField: "wired.file.owner") {
            self.owner = value
        }
        if let value = message.string(forField: "wired.file.group") {
            self.group = value
        }
        if let value = message.bool(forField: "wired.file.owner.read") {
            self.ownerRead = value
        }
        if let value = message.bool(forField: "wired.file.owner.write") {
            self.ownerWrite = value
        }
        if let value = message.bool(forField: "wired.file.group.read") {
            self.groupRead = value
        }
        if let value = message.bool(forField: "wired.file.group.write") {
            self.groupWrite = value
        }
        if let value = message.bool(forField: "wired.file.everyone.read") {
            self.everyoneRead = value
        }
        if let value = message.bool(forField: "wired.file.everyone.write") {
            self.everyoneWrite = value
        }
        if let value = message.bool(forField: "wired.file.readable") {
            self.readable = value
        }
        if let value = message.bool(forField: "wired.file.writable") {
            self.writable = value
        }
        if let value = message.string(forField: "wired.file.sync.user_mode"),
           let mode = SyncModeValue(rawValue: value) {
            self.syncUserMode = mode
        }
        if let value = message.string(forField: "wired.file.sync.group_mode"),
           let mode = SyncModeValue(rawValue: value) {
            self.syncGroupMode = mode
        }
        if let value = message.string(forField: "wired.file.sync.everyone_mode"),
           let mode = SyncModeValue(rawValue: value) {
            self.syncEveryoneMode = mode
        }
        if let value = message.string(forField: "wired.file.sync.mode_effective"),
           let mode = SyncModeValue(rawValue: value) {
            self.syncEffectiveMode = mode
        }
        if let v = message.uint64(forField: "wired.file.sync.max_file_size_bytes") {
            self.syncMaxFileSizeBytes = v
        }
        if let v = message.uint64(forField: "wired.file.sync.max_tree_size_bytes") {
            self.syncMaxTreeSizeBytes = v
        }
        if let v = message.string(forField: "wired.file.sync.exclude_patterns") {
            self.syncExcludePatterns = v
        }
    }
}

struct FileColumn: Identifiable {
    let id = UUID()
    let path: String
    var items: [FileItem]
    var selection: UUID?
}

enum FileViewType: Int {
    case tree
    case columns
}
