import SwiftUI
import WiredSwift
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    static let wiredRemoteFile = UTType(importedAs: "com.read-write.wired.remote-file")
}

func resolvedDragItemName(preferredName: String, path: String, fallback: String) -> String {
    let trimmed = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }

    let fromPath = (path as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fromPath.isEmpty && fromPath != "/" {
        return fromPath
    }

    return fallback
}

struct RemoteFileDragPayload: Codable, Transferable {
    let path: String
    let name: String
    let connectionID: UUID

    var asFileItem: FileItem {
        let effectiveName = resolvedDragItemName(preferredName: name, path: path, fallback: "file")
        return FileItem(
            effectiveName,
            path: path,
            type: .file
        )
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item, shouldAllowToOpenInPlace: true) { item in
            guard let url = FinderDragExportBroker.shared.prepareExport(for: item) else {
                throw NSError(
                    domain: "Wired.DragAndDrop",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to stage file placeholder for Finder drag."]
                )
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }

        CodableRepresentation(contentType: .wiredRemoteFile)
    }
}

struct RemoteFolderDragPayload: Codable, Transferable {
    let path: String
    let name: String
    let connectionID: UUID

    var asFileItem: FileItem {
        let effectiveName = resolvedDragItemName(preferredName: name, path: path, fallback: "folder")
        return FileItem(effectiveName, path: path, type: .directory)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item, shouldAllowToOpenInPlace: true) { item in
            guard let url = FinderDragExportBroker.shared.prepareExport(for: item) else {
                throw NSError(
                    domain: "Wired.DragAndDrop",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to stage folder placeholder for Finder drag."]
                )
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }

        CodableRepresentation(contentType: .wiredRemoteFile)
    }
}

final class FinderDragExportBroker {
    static let shared = FinderDragExportBroker()

    private init() {}

    func configure(transferManager: TransferManager) {
        _ = transferManager
    }

    func prepareExport(for payload: RemoteFileDragPayload) -> URL? {
        prepareExport(file: payload.asFileItem, connectionID: payload.connectionID)
    }

    func prepareExport(for payload: RemoteFolderDragPayload) -> URL? {
        prepareExport(file: payload.asFileItem, connectionID: payload.connectionID)
    }

    private func prepareExport(file: FileItem, connectionID: UUID) -> URL? {
        guard isDownloadableRemoteItem(file) else { return nil }

        let stagedURL = dragExportStagingURL(for: file, connectionID: connectionID)
        let stagedPath = stagedURL.path
        let fm = FileManager.default

        if fm.fileExists(atPath: stagedPath) {
            try? fm.removeItem(atPath: stagedPath)
        }

        if file.type == .file {
            guard fm.createFile(atPath: stagedPath, contents: nil, attributes: nil) else {
                return nil
            }
            return stagedURL
        }

        do {
            try fm.createDirectory(at: stagedURL, withIntermediateDirectories: true)
            return stagedURL
        } catch {
            return nil
        }
    }
}

func dragExportFileName(for item: FileItem) -> String {
    let name = item.name.isEmpty ? (item.path as NSString).lastPathComponent : item.name
    return name.isEmpty ? "file" : name
}

func dragExportTemporaryURL(for item: FileItem, connectionID: UUID) -> URL {
    _ = connectionID
    let fileName = dragExportFileName(for: item)
    let unique = UUID().uuidString
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("WiredDragExports", isDirectory: true)
        .appendingPathComponent(unique, isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let isDirectory = item.type.isDirectoryLike
    return base.appendingPathComponent(fileName, isDirectory: isDirectory)
}

func dragExportStagingURL(for item: FileItem, connectionID: UUID) -> URL {
    let baseURL = dragExportTemporaryURL(for: item, connectionID: connectionID)
    let isDirectory = item.type.isDirectoryLike
    guard !isDirectory else { return baseURL }
    let partialName = baseURL.lastPathComponent + ".\(Wired.transfersFileExtension)"
    return baseURL.deletingLastPathComponent().appendingPathComponent(partialName, isDirectory: false)
}

func isDownloadableRemoteItem(_ item: FileItem) -> Bool {
    if item.path == "/" { return false }
    return item.type == .file || item.type.isDirectoryLike
}

extension View {
    @ViewBuilder
    func remoteDraggable(item: FileItem, connectionID: UUID, isDirectory: Bool) -> some View {
        if isDirectory {
            self.draggable(
                RemoteFolderDragPayload(
                    path: item.path,
                    name: resolvedDragItemName(preferredName: item.name, path: item.path, fallback: "folder"),
                    connectionID: connectionID
                )
            )
        } else {
            self.draggable(
                RemoteFileDragPayload(
                    path: item.path,
                    name: resolvedDragItemName(preferredName: item.name, path: item.path, fallback: "file"),
                    connectionID: connectionID
                )
            )
        }
    }
}
