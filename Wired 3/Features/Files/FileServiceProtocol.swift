//
//  FileServiceProtocol.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 11/01/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import WiredSwift
import Foundation

struct DropboxPermissions {
    let owner: String
    let group: String
    let ownerRead: Bool
    let ownerWrite: Bool
    let groupRead: Bool
    let groupWrite: Bool
    let everyoneRead: Bool
    let everyoneWrite: Bool
}

struct SyncPolicyPayload {
    let userMode: SyncModeValue
    let groupMode: SyncModeValue
    let everyoneMode: SyncModeValue
    let maxFileSizeBytes: UInt64
    let maxTreeSizeBytes: UInt64
    let excludePatterns: String
}

protocol FileServiceProtocol {
    func listDirectory(
        path: String,
        recursive: Bool,
        connection: AsyncConnection
    ) -> AsyncThrowingStream<FileItem, Error>

    func deleteFile(
        path: String,
        connection: AsyncConnection
    ) async throws

    func createDirectory(
        path: String,
        type: FileType,
        connection: AsyncConnection
    ) async throws

    func moveFile(
        from sourcePath: String,
        to destinationPath: String,
        connection: AsyncConnection
    ) async throws

    func linkFile(
        from sourcePath: String,
        to destinationPath: String,
        connection: AsyncConnection
    ) async throws

    func setFileType(
        path: String,
        type: FileType,
        connection: AsyncConnection
    ) async throws

    func setFileComment(
        path: String,
        comment: String,
        connection: AsyncConnection
    ) async throws

    func setFileLabel(
        path: String,
        label: FileLabelValue,
        connection: AsyncConnection
    ) async throws

    func setFilePermissions(
        path: String,
        permissions: DropboxPermissions,
        connection: AsyncConnection
    ) async throws

    func setFileSyncPolicy(
        path: String,
        policy: SyncPolicyPayload,
        connection: AsyncConnection
    ) async throws

    func getFileInfo(
        path: String,
        connection: AsyncConnection
    ) async throws -> FileItem

    func previewFile(
        path: String,
        connection: AsyncConnection
    ) async throws -> Data

    func listUserNames(connection: AsyncConnection) async throws -> [String]
    func listGroupNames(connection: AsyncConnection) async throws -> [String]

    func subscribeDirectory(
        path: String,
        connection: AsyncConnection
    ) async throws

    func unsubscribeDirectory(
        path: String,
        connection: AsyncConnection
    ) async throws

    func searchFiles(
        query: String,
        connection: AsyncConnection
    ) -> AsyncThrowingStream<FileItem, Error>
}

final class FileService: FileServiceProtocol {
    func listDirectory(
        path: String,
        recursive: Bool = false,
        connection: AsyncConnection
    ) -> AsyncThrowingStream<FileItem, Error> {

        let message = P7Message(
            withName: "wired.file.list_directory",
            spec: spec
        )
        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.recursive", value: recursive)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await response in try connection.sendAndWaitMany(message) {
                        if response.name == "wired.file.file_list" {
                            continuation.yield(
                                FileItem(response, connection: connection)
                            )
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func deleteFile(
        path: String,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.delete",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func createDirectory(
        path: String,
        type: FileType,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.create_directory",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.type", value: type.rawValue)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func moveFile(
        from sourcePath: String,
        to destinationPath: String,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.move",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: sourcePath)
        message.addParameter(field: "wired.file.new_path", value: destinationPath)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func linkFile(
        from sourcePath: String,
        to destinationPath: String,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.link",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: sourcePath)
        message.addParameter(field: "wired.file.new_path", value: destinationPath)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func setFileType(
        path: String,
        type: FileType,
        connection: AsyncConnection
    ) async throws {
        guard type != .file else { return }

        let message = P7Message(
            withName: "wired.file.set_type",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.type", value: type.rawValue)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func setFileComment(
        path: String,
        comment: String,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.set_comment",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.comment", value: comment)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func setFileLabel(
        path: String,
        label: FileLabelValue,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.set_label",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.label", value: label.rawValue)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func setFilePermissions(
        path: String,
        permissions: DropboxPermissions,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.set_permissions",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.owner", value: permissions.owner)
        message.addParameter(field: "wired.file.owner.read", value: permissions.ownerRead)
        message.addParameter(field: "wired.file.owner.write", value: permissions.ownerWrite)
        message.addParameter(field: "wired.file.group", value: permissions.group)
        message.addParameter(field: "wired.file.group.read", value: permissions.groupRead)
        message.addParameter(field: "wired.file.group.write", value: permissions.groupWrite)
        message.addParameter(field: "wired.file.everyone.read", value: permissions.everyoneRead)
        message.addParameter(field: "wired.file.everyone.write", value: permissions.everyoneWrite)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func setFileSyncPolicy(
        path: String,
        policy: SyncPolicyPayload,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.set_sync_policy",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)
        message.addParameter(field: "wired.file.sync.user_mode", value: policy.userMode.rawValue)
        message.addParameter(field: "wired.file.sync.group_mode", value: policy.groupMode.rawValue)
        message.addParameter(field: "wired.file.sync.everyone_mode", value: policy.everyoneMode.rawValue)
        message.addParameter(field: "wired.file.sync.max_file_size_bytes", value: policy.maxFileSizeBytes)
        message.addParameter(field: "wired.file.sync.max_tree_size_bytes", value: policy.maxTreeSizeBytes)
        if !policy.excludePatterns.isEmpty {
            message.addParameter(field: "wired.file.sync.exclude_patterns", value: policy.excludePatterns)
        }

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func getFileInfo(
        path: String,
        connection: AsyncConnection
    ) async throws -> FileItem {
        let message = P7Message(
            withName: "wired.file.get_info",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)

        let response = try await connection.sendAsync(message)

        guard let response else {
            throw WiredError(withTitle: "File Info Error", message: "No response from server")
        }

        if response.name == "wired.error" {
            throw WiredError(message: response)
        }

        guard response.name == "wired.file.info" else {
            throw WiredError(withTitle: "File Info Error", message: "Invalid response: \(response.name ?? "unknown")")
        }

        return FileItem(response, connection: connection)
    }

    func previewFile(
        path: String,
        connection: AsyncConnection
    ) async throws -> Data {
        let message = P7Message(
            withName: "wired.file.preview_file",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)

        guard let response = try await connection.sendAsync(message) else {
            throw WiredError(withTitle: "Quick Look Error", message: "No response from server")
        }

        if response.name == "wired.error" {
            throw WiredError(message: response)
        }

        guard response.name == "wired.file.preview",
              let data = response.data(forField: "wired.file.preview") else {
            throw WiredError(withTitle: "Quick Look Error", message: "Invalid response: \(response.name ?? "unknown")")
        }

        return data
    }

    func listUserNames(connection: AsyncConnection) async throws -> [String] {
        let message = P7Message(withName: "wired.account.list_users", spec: spec)
        var values: [String] = []

        for try await response in try connection.sendAndWaitMany(message) {
            if response.name == "wired.error" {
                throw WiredError(message: response)
            }

            if response.name == "wired.account.user_list",
               let name = response.string(forField: "wired.account.name"),
               !name.isEmpty {
                values.append(name)
            }
        }

        return Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func listGroupNames(connection: AsyncConnection) async throws -> [String] {
        let message = P7Message(withName: "wired.account.list_groups", spec: spec)
        var values: [String] = []

        for try await response in try connection.sendAndWaitMany(message) {
            if response.name == "wired.error" {
                throw WiredError(message: response)
            }

            if response.name == "wired.account.group_list",
               let name = response.string(forField: "wired.account.name"),
               !name.isEmpty {
                values.append(name)
            }
        }

        return Array(Set(values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func subscribeDirectory(
        path: String,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.subscribe_directory",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func unsubscribeDirectory(
        path: String,
        connection: AsyncConnection
    ) async throws {
        let message = P7Message(
            withName: "wired.file.unsubscribe_directory",
            spec: spec
        )

        message.addParameter(field: "wired.file.path", value: path)

        let response = try await connection.sendAsync(message)

        if response?.name == "wired.error" {
            throw WiredError(message: response!)
        }
    }

    func searchFiles(
        query: String,
        connection: AsyncConnection
    ) -> AsyncThrowingStream<FileItem, Error> {
        let message = P7Message(withName: "wired.file.search", spec: spec)
        message.addParameter(field: "wired.file.query", value: query)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await response in try connection.sendAndWaitMany(message) {
                        if response.name == "wired.file.search_list" {
                            continuation.yield(FileItem(response, connection: connection))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

}
