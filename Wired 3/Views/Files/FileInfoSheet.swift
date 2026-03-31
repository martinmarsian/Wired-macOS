//
//  FileInfoSheet.swift
//  Wired 3
//
//  Created by Codex on 18/02/2026.
//

import SwiftUI

private enum DropboxAccessLevel: String, CaseIterable, Identifiable {
    case denied
    case readWrite
    case readOnly
    case writeOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .denied: return "Acces interdit"
        case .readWrite: return "Lecture et ecriture"
        case .readOnly: return "Lecture seulement"
        case .writeOnly: return "Ecriture seulement"
        }
    }

    var readEnabled: Bool {
        self == .readWrite || self == .readOnly
    }

    var writeEnabled: Bool {
        self == .readWrite || self == .writeOnly
    }

    static func from(read: Bool, write: Bool) -> DropboxAccessLevel {
        switch (read, write) {
        case (false, false): return .denied
        case (true, true): return .readWrite
        case (true, false): return .readOnly
        case (false, true): return .writeOnly
        }
    }
}

private enum SyncAccessMode: String, CaseIterable, Identifiable {
    case serverToClient = "server_to_client"
    case clientToServer = "client_to_server"
    case bidirectional = "bidirectional"

    var id: String { rawValue }

    var title: String {
        rawValue
    }

    var readEnabled: Bool {
        self == .serverToClient || self == .bidirectional
    }

    var writeEnabled: Bool {
        self == .clientToServer || self == .bidirectional
    }

    static func from(read: Bool, write: Bool) -> SyncAccessMode {
        switch (read, write) {
        case (true, false):
            return .serverToClient
        case (false, true):
            return .clientToServer
        case (true, true):
            return .bidirectional
        case (false, false):
            // Sync v1 only exposes 3 operational modes.
            return .serverToClient
        }
    }
}

struct FileInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionRuntime.self) private var runtime

    @ObservedObject var filesViewModel: FilesViewModel
    let file: FileItem

    @State private var info: FileItem
    @State private var selectedTypeRawValue: UInt32
    @State private var isLoadingInfo = false
    @State private var isSaving = false
    @State private var isLoadingAccounts = false
    @State private var ownerNames: [String] = []
    @State private var groupNames: [String] = []
    @State private var ownerSelection = ""
    @State private var groupSelection = ""
    @State private var ownerAccess: DropboxAccessLevel = .denied
    @State private var groupAccess: DropboxAccessLevel = .denied
    @State private var everyoneAccess: DropboxAccessLevel = .denied
    @State private var syncOwnerMode: SyncAccessMode = .bidirectional
    @State private var syncGroupMode: SyncAccessMode = .bidirectional
    @State private var syncEveryoneMode: SyncAccessMode = .bidirectional

    init(filesViewModel: FilesViewModel, file: FileItem) {
        self.filesViewModel = filesViewModel
        self.file = file
        _info = State(initialValue: file)
        _selectedTypeRawValue = State(initialValue: file.type.rawValue)
    }

    private var selectedType: FileType {
        FileType(rawValue: selectedTypeRawValue) ?? .directory
    }

    private var isDirectoryType: Bool {
        info.type.isDirectoryLike
    }

    private var isInsideSyncSubtree: Bool {
        filesViewModel.isInsideSyncTree(info.path)
    }

    private var availableFolderTypes: [FileType] {
        if isInsideSyncSubtree {
            return [.directory]
        }
        return [.directory, .uploads, .dropbox, .sync]
    }

    private var canEditType: Bool {
        isDirectoryType && runtime.hasPrivilege("wired.account.file.set_type")
    }

    private var hasChanges: Bool {
        selectedTypeRawValue != info.type.rawValue || hasDropboxPermissionChanges
    }

    private var hasDropboxPermissionChanges: Bool {
        guard info.type.isManagedAccessType else { return false }
        if info.type == .sync {
            return syncOwnerMode != SyncAccessMode.from(read: info.ownerRead, write: info.ownerWrite)
                || syncGroupMode != SyncAccessMode.from(read: info.groupRead, write: info.groupWrite)
                || syncEveryoneMode != SyncAccessMode.from(read: info.everyoneRead, write: info.everyoneWrite)
                || ownerSelection != info.owner
                || groupSelection != info.group
        }
        return ownerSelection != info.owner
        || groupSelection != info.group
        || ownerAccess != .from(read: info.ownerRead, write: info.ownerWrite)
        || groupAccess != .from(read: info.groupRead, write: info.groupWrite)
        || everyoneAccess != .from(read: info.everyoneRead, write: info.everyoneWrite)
    }

    private var canEditDropboxPermissions: Bool {
        info.type.isManagedAccessType && (runtime.hasPrivilege("wired.account.file.set_permissions") || info.writable)
    }

    private var canSaveChanges: Bool {
        let canSaveTypeChange = canEditType && selectedTypeRawValue != info.type.rawValue
        let canSaveDropboxChange = canEditDropboxPermissions && hasDropboxPermissionChanges
        return canSaveTypeChange || canSaveDropboxChange
    }

    private var totalSizeString: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(info.dataSize + info.rsrcSize),
            countStyle: .file
        )
    }

    private func byteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(value),
            countStyle: .file
        )
    }

    private func dateString(_ value: Date?) -> String {
        guard let value else { return "-" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    LabeledContent("Name", value: info.name)
                    LabeledContent("Path", value: info.path)
                    LabeledContent("Type", value: info.type.description)
                    LabeledContent("Created", value: dateString(info.creationDate))
                    LabeledContent("Modified", value: dateString(info.modificationDate))
                }

                if info.type == .file {
                    Section("File") {
                        LabeledContent("Data", value: byteString(info.dataSize))
                        LabeledContent("Resource", value: byteString(info.rsrcSize))
                        LabeledContent("Total", value: totalSizeString)
                    }
                } else {
                    Section("Folder") {
                        LabeledContent("Contains", value: "\(info.directoryCount) items")
                    }

                    Section("Folder Type") {
                        Picker("Type", selection: $selectedTypeRawValue) {
                            ForEach(availableFolderTypes, id: \.rawValue) { type in
                                Text(type.description).tag(type.rawValue)
                            }
                        }
                        .disabled(!canEditType)
                    }

                    if info.type.isManagedAccessType {
                        Section("Managed Folder Permissions") {
                            Picker("Owner", selection: $ownerSelection) {
                                Text("Aucun").tag("")
                                ForEach(ownerNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .disabled(!canEditDropboxPermissions || isLoadingAccounts)

                            if info.type == .sync {
                                Picker("User Mode", selection: $syncOwnerMode) {
                                    ForEach(SyncAccessMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .disabled(!canEditDropboxPermissions)
                            } else {
                                Picker("Owner Access", selection: $ownerAccess) {
                                    ForEach(DropboxAccessLevel.allCases) { level in
                                        Text(level.title).tag(level)
                                    }
                                }
                                .disabled(!canEditDropboxPermissions)
                            }

                            Picker("Group", selection: $groupSelection) {
                                Text("Aucun").tag("")
                                ForEach(groupNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .disabled(!canEditDropboxPermissions || isLoadingAccounts)

                            if info.type == .sync {
                                Picker("Group Mode", selection: $syncGroupMode) {
                                    ForEach(SyncAccessMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .disabled(!canEditDropboxPermissions)
                            } else {
                                Picker("Group Access", selection: $groupAccess) {
                                    ForEach(DropboxAccessLevel.allCases) { level in
                                        Text(level.title).tag(level)
                                    }
                                }
                                .disabled(!canEditDropboxPermissions)
                            }

                            if info.type == .sync {
                                Picker("Everyone Mode", selection: $syncEveryoneMode) {
                                    ForEach(SyncAccessMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .disabled(!canEditDropboxPermissions)
                            } else {
                                Picker("Everyone", selection: $everyoneAccess) {
                                    ForEach(DropboxAccessLevel.allCases) { level in
                                        Text(level.title).tag(level)
                                    }
                                }
                                .disabled(!canEditDropboxPermissions)
                            }
                        }
                    }
                }
            }
            .navigationTitle("File Info")
            .overlay {
                if isLoadingInfo || isLoadingAccounts {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(!canSaveChanges || isSaving)
                }
            }
            .task {
                await loadInfo()
                await loadAccounts()
            }
        }
    }

    @MainActor
    private func loadInfo() async {
        isLoadingInfo = true
        defer { isLoadingInfo = false }

        do {
            let loadedInfo = try await filesViewModel.getFileInfo(path: file.path)
            info = loadedInfo
            selectedTypeRawValue = loadedInfo.type.rawValue
            if isInsideSyncSubtree && selectedTypeRawValue != FileType.directory.rawValue {
                selectedTypeRawValue = FileType.directory.rawValue
            }
            ownerSelection = loadedInfo.owner
            groupSelection = loadedInfo.group
            ownerAccess = .from(read: loadedInfo.ownerRead, write: loadedInfo.ownerWrite)
            groupAccess = .from(read: loadedInfo.groupRead, write: loadedInfo.groupWrite)
            everyoneAccess = .from(read: loadedInfo.everyoneRead, write: loadedInfo.everyoneWrite)
            syncOwnerMode = .from(read: loadedInfo.ownerRead, write: loadedInfo.ownerWrite)
            syncGroupMode = .from(read: loadedInfo.groupRead, write: loadedInfo.groupWrite)
            syncEveryoneMode = .from(read: loadedInfo.everyoneRead, write: loadedInfo.everyoneWrite)
        } catch {
            filesViewModel.error = error
        }
    }

    @MainActor
    private func loadAccounts() async {
        guard info.type.isManagedAccessType else { return }

        isLoadingAccounts = true
        defer { isLoadingAccounts = false }

        do {
            async let users = filesViewModel.listUserNames()
            async let groups = filesViewModel.listGroupNames()
            ownerNames = try await users
            groupNames = try await groups
        } catch {
            filesViewModel.error = error
        }
    }

    @MainActor
    private func save() async {
        guard hasChanges else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            if selectedType != info.type, canEditType {
                try await filesViewModel.setFileType(path: info.path, type: selectedType)
            }

            if info.type.isManagedAccessType, hasDropboxPermissionChanges, canEditDropboxPermissions {
                let ownerRead: Bool
                let ownerWrite: Bool
                let groupRead: Bool
                let groupWrite: Bool
                let everyoneRead: Bool
                let everyoneWrite: Bool

                if info.type == .sync {
                    ownerRead = syncOwnerMode.readEnabled
                    ownerWrite = syncOwnerMode.writeEnabled
                    groupRead = syncGroupMode.readEnabled
                    groupWrite = syncGroupMode.writeEnabled
                    everyoneRead = syncEveryoneMode.readEnabled
                    everyoneWrite = syncEveryoneMode.writeEnabled
                } else {
                    ownerRead = ownerAccess.readEnabled
                    ownerWrite = ownerAccess.writeEnabled
                    groupRead = groupAccess.readEnabled
                    groupWrite = groupAccess.writeEnabled
                    everyoneRead = everyoneAccess.readEnabled
                    everyoneWrite = everyoneAccess.writeEnabled
                }

                let permissions = DropboxPermissions(
                    owner: ownerSelection,
                    group: groupSelection,
                    ownerRead: ownerRead,
                    ownerWrite: ownerWrite,
                    groupRead: groupRead,
                    groupWrite: groupWrite,
                    everyoneRead: everyoneRead,
                    everyoneWrite: everyoneWrite
                )
                try await filesViewModel.setFilePermissions(path: info.path, permissions: permissions)
            }
            dismiss()
        } catch {
            filesViewModel.error = error
        }
    }
}
