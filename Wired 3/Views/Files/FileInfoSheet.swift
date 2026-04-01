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
        case .denied:    return "No Access"
        case .readWrite: return "Read & Write"
        case .readOnly:  return "Read Only"
        case .writeOnly: return "Write Only"
        }
    }

    var readEnabled: Bool  { self == .readWrite || self == .readOnly }
    var writeEnabled: Bool { self == .readWrite || self == .writeOnly }

    static func from(read: Bool, write: Bool) -> DropboxAccessLevel {
        switch (read, write) {
        case (false, false): return .denied
        case (true,  true):  return .readWrite
        case (true,  false): return .readOnly
        case (false, true):  return .writeOnly
        }
    }
}

private enum SyncAccessMode: String, CaseIterable, Identifiable {
    case disabled       = "disabled"
    case serverToClient = "server_to_client"
    case clientToServer = "client_to_server"
    case bidirectional  = "bidirectional"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled:       return "Disabled"
        case .serverToClient: return "Server → Client"
        case .clientToServer: return "Client → Server"
        case .bidirectional:  return "Bidirectional"
        }
    }

    static func from(mode: SyncModeValue) -> SyncAccessMode {
        SyncAccessMode(rawValue: mode.rawValue) ?? .disabled
    }

    var value: SyncModeValue {
        SyncModeValue(rawValue: rawValue) ?? .disabled
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
    @State private var syncOwnerMode: SyncAccessMode = .disabled
    @State private var syncGroupMode: SyncAccessMode = .disabled
    @State private var syncEveryoneMode: SyncAccessMode = .disabled
    @State private var newName: String = ""

    init(filesViewModel: FilesViewModel, file: FileItem) {
        self.filesViewModel = filesViewModel
        self.file = file
        _info = State(initialValue: file)
        _selectedTypeRawValue = State(initialValue: file.type.rawValue)
        _newName = State(initialValue: file.name)
    }

    // MARK: - Computed

    private var selectedType: FileType {
        FileType(rawValue: selectedTypeRawValue) ?? .directory
    }

    private var isDirectoryType: Bool { info.type.isDirectoryLike }
    private var isInsideSyncSubtree: Bool { filesViewModel.isInsideSyncTree(info.path) }

    private var availableFolderTypes: [FileType] {
        isInsideSyncSubtree ? [.directory] : [.directory, .uploads, .dropbox, .sync]
    }

    private var canEditType: Bool {
        isDirectoryType && runtime.hasPrivilege("wired.account.file.set_type")
    }

    private var hasManagedPermissionChanges: Bool {
        guard info.type.isManagedAccessType else { return false }
        return ownerSelection   != info.owner
            || groupSelection   != info.group
            || ownerAccess      != .from(read: info.ownerRead,     write: info.ownerWrite)
            || groupAccess      != .from(read: info.groupRead,     write: info.groupWrite)
            || everyoneAccess   != .from(read: info.everyoneRead,  write: info.everyoneWrite)
    }

    private var hasSyncPolicyChanges: Bool {
        guard info.type == .sync else { return false }
        return syncOwnerMode    != .from(mode: info.syncUserMode)
            || syncGroupMode    != .from(mode: info.syncGroupMode)
            || syncEveryoneMode != .from(mode: info.syncEveryoneMode)
    }

    private var hasRenameChange: Bool {
        !newName.isEmpty && newName != info.name
    }

    private var hasChanges: Bool {
        hasRenameChange || selectedTypeRawValue != info.type.rawValue || hasManagedPermissionChanges || hasSyncPolicyChanges
    }

    private var canEditManagedPermissions: Bool {
        info.type.isManagedAccessType &&
        (runtime.hasPrivilege("wired.account.file.set_permissions") || info.writable)
    }

    private var canSaveChanges: Bool {
        hasRenameChange
        || (canEditType && selectedTypeRawValue != info.type.rawValue)
        || (canEditManagedPermissions && hasManagedPermissionChanges)
        || (canEditManagedPermissions && hasSyncPolicyChanges)
    }

    private var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(info.dataSize + info.rsrcSize), countStyle: .file)
    }

    private func byteString(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func dateString(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    headerCard

                    if info.type == .file {
                        sizeCard
                    } else {
                        folderCard
                        if info.type.isManagedAccessType {
                            permissionsCard
                            if info.type == .sync {
                                syncPolicyCard
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("File Info")
            .overlay {
                if isLoadingInfo || isLoadingAccounts {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSaveChanges || isSaving)
                }
            }
            .task {
                await loadInfo()
                await loadAccounts()
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 300)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: fileIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(info.type == .file ? Color.secondary : Color.accentColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $newName)
                    .font(.title3).fontWeight(.semibold)
                    .textFieldStyle(.plain)
                    .lineLimit(1)

                Text(info.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    typeBadge
                    if let created = info.creationDate {
                        metaChip("calendar", dateString(created))
                    }
                    if let modified = info.modificationDate {
                        metaChip("clock", dateString(modified))
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var fileIcon: String {
        switch info.type {
        case .file:     return "doc.fill"
        case .uploads:  return "arrow.up.doc.fill"
        case .dropbox:  return "tray.fill"
        case .sync:     return "arrow.2.circlepath"
        default:        return "folder.fill"
        }
    }

    private var typeBadge: some View {
        Text(info.type.description)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Size Card

    private var sizeCard: some View {
        infoCard(title: "Size", systemImage: "doc.badge.ellipsis") {
            infoRow("Data", byteString(info.dataSize))
            cardDivider
            infoRow("Resource", byteString(info.rsrcSize))
            cardDivider
            infoRow("Total", totalSizeString)
        }
    }

    // MARK: - Folder Card

    private var folderCard: some View {
        infoCard(title: "Folder", systemImage: "folder") {
            infoRow("Contains", "\(info.directoryCount) items")
            cardDivider
            HStack {
                Text("Type")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $selectedTypeRawValue) {
                    ForEach(availableFolderTypes, id: \.rawValue) { type in
                        Text(type.description).tag(type.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!canEditType)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    // MARK: - Permissions Card

    private var permissionsCard: some View {
        infoCard(title: "Folder Permissions", systemImage: "lock.fill") {
            HStack {
                Text("Account")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(width: labelWidth, alignment: .leading)
                Spacer()
                Text("Access")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6).padding(.bottom, 4)

            cardDivider

            permissionRow(
                label: "Owner",
                nameBinding: $ownerSelection,
                names: ownerNames,
                accessBinding: $ownerAccess
            )
            cardDivider
            permissionRow(
                label: "Group",
                nameBinding: $groupSelection,
                names: groupNames,
                accessBinding: $groupAccess
            )
            cardDivider

            HStack {
                Text("Everyone")
                    .font(.subheadline)
                    .frame(width: labelWidth, alignment: .leading)
                Spacer()
                Picker("", selection: $everyoneAccess) {
                    ForEach(DropboxAccessLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!canEditManagedPermissions)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func permissionRow(
        label: String,
        nameBinding: Binding<String>,
        names: [String],
        accessBinding: Binding<DropboxAccessLevel>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .frame(width: labelWidth, alignment: .leading)

            Picker("", selection: nameBinding) {
                Text("None").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!canEditManagedPermissions || isLoadingAccounts)

            Spacer()

            Picker("", selection: accessBinding) {
                ForEach(DropboxAccessLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!canEditManagedPermissions)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Sync Policy Card

    private var syncPolicyCard: some View {
        infoCard(title: "Sync Policy", systemImage: "arrow.2.circlepath") {
            syncModeRow("Owner",    $syncOwnerMode)
            cardDivider
            syncModeRow("Group",    $syncGroupMode)
            cardDivider
            syncModeRow("Everyone", $syncEveryoneMode)
            cardDivider

            HStack {
                Text("Effective Mode")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(SyncAccessMode.from(mode: info.syncEffectiveMode).title)
                    .font(.subheadline).fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func syncModeRow(_ label: String, _ binding: Binding<SyncAccessMode>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .frame(width: labelWidth, alignment: .leading)
            Spacer()
            Picker("", selection: binding) {
                ForEach(SyncAccessMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!canEditManagedPermissions)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Reusable Primitives

    private let labelWidth: CGFloat = 72

    private var cardDivider: some View {
        Divider().padding(.horizontal, 14)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func infoCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)

            Divider()

            content()
        }
        .background(.fill.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Data Loading

    @MainActor
    private func loadInfo() async {
        isLoadingInfo = true
        defer { isLoadingInfo = false }
        do {
            let loadedInfo = try await filesViewModel.getFileInfo(path: file.path)
            info = loadedInfo
            newName = loadedInfo.name
            selectedTypeRawValue = loadedInfo.type.rawValue
            if isInsideSyncSubtree && selectedTypeRawValue != FileType.directory.rawValue {
                selectedTypeRawValue = FileType.directory.rawValue
            }
            ownerSelection   = loadedInfo.owner
            groupSelection   = loadedInfo.group
            ownerAccess      = .from(read: loadedInfo.ownerRead,    write: loadedInfo.ownerWrite)
            groupAccess      = .from(read: loadedInfo.groupRead,    write: loadedInfo.groupWrite)
            everyoneAccess   = .from(read: loadedInfo.everyoneRead, write: loadedInfo.everyoneWrite)
            syncOwnerMode    = .from(mode: loadedInfo.syncUserMode)
            syncGroupMode    = .from(mode: loadedInfo.syncGroupMode)
            syncEveryoneMode = .from(mode: loadedInfo.syncEveryoneMode)
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
            async let users  = filesViewModel.listUserNames()
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
            if hasRenameChange {
                let newPath = try await filesViewModel.renameItem(
                    at: info.path,
                    newName: newName,
                    isSyncFolder: info.type == .sync
                )
                // Update local info so subsequent operations use the new path.
                info.path = newPath
                info.name = newName
            }

            if selectedType != info.type, canEditType {
                try await filesViewModel.setFileType(path: info.path, type: selectedType)
            }
            if info.type.isManagedAccessType, hasManagedPermissionChanges, canEditManagedPermissions {
                let permissions = DropboxPermissions(
                    owner: ownerSelection,
                    group: groupSelection,
                    ownerRead:     ownerAccess.readEnabled,
                    ownerWrite:    ownerAccess.writeEnabled,
                    groupRead:     groupAccess.readEnabled,
                    groupWrite:    groupAccess.writeEnabled,
                    everyoneRead:  everyoneAccess.readEnabled,
                    everyoneWrite: everyoneAccess.writeEnabled
                )
                try await filesViewModel.setFilePermissions(path: info.path, permissions: permissions)
            }
            if info.type == .sync, hasSyncPolicyChanges, canEditManagedPermissions {
                let policy = SyncPolicyPayload(
                    userMode:     syncOwnerMode.value,
                    groupMode:    syncGroupMode.value,
                    everyoneMode: syncEveryoneMode.value
                )
                try await filesViewModel.setFileSyncPolicy(path: info.path, policy: policy)
            }
            dismiss()
        } catch {
            filesViewModel.error = error
        }
    }
}
