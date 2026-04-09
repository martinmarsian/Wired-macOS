//
//  ChatAttachment.swift
//  Wired 3
//

import Foundation
import UniformTypeIdentifiers
import WiredSwift

struct ChatAttachmentDescriptor: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let mediaType: String
    let size: UInt64
    let sha256: String
    let inlinePreview: Bool
    let width: UInt32?
    let height: UInt32?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mediaType = "media_type"
        case size
        case sha256
        case inlinePreview = "inline_preview"
        case width
        case height
    }

    var isImage: Bool {
        mediaType.lowercased().hasPrefix("image/")
    }

    var fileSizeDescription: String {
        byteCountFormatter.string(fromByteCount: Int64(size))
    }

    var preferredFilenameExtension: String? {
        URL(fileURLWithPath: name).pathExtension.nilIfEmpty
            ?? UTType(mimeType: mediaType)?.preferredFilenameExtension
    }

    static func descriptors(from message: P7Message) -> [ChatAttachmentDescriptor] {
        let entries = message.stringList(forField: "wired.attachment.descriptors") ?? []
        let decoder = JSONDecoder()
        return entries.compactMap { entry in
            guard let data = entry.data(using: .utf8) else { return nil }
            return try? decoder.decode(ChatAttachmentDescriptor.self, from: data)
        }
    }
}

struct ChatDraftAttachment: Equatable, Identifiable {
    static let maxSizeBytes: UInt64 = 16 * 1_024 * 1_024
    static let maxAttachmentsPerMessage = 8
    static let maxTotalSizeBytes: UInt64 = 32 * 1_024 * 1_024

    let id = UUID()
    let fileURL: URL
    let fileName: String
    let mediaType: String
    let size: UInt64

    init(fileURL: URL) throws {
        let normalizedURL = fileURL.standardizedFileURL
        let values = try normalizedURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentTypeKey,
            .nameKey
        ])

        guard values.isRegularFile == true else {
            throw WiredError(withTitle: "Attachment", message: "Only regular files can be attached to a chat message.")
        }

        self.fileURL = normalizedURL
        self.fileName = values.name ?? normalizedURL.lastPathComponent
        self.size = UInt64(max(values.fileSize ?? 0, 0))

        guard size > 0 else {
            throw WiredError(withTitle: "Attachment", message: "Empty files cannot be attached to a chat message.")
        }

        guard size <= Self.maxSizeBytes else {
            throw WiredError(
                withTitle: "Attachment",
                message: "This file is too large. Chat attachments are currently limited to \(byteCountFormatter.string(fromByteCount: Int64(Self.maxSizeBytes)))."
            )
        }

        if let type = values.contentType {
            self.mediaType = type.preferredMIMEType ?? "application/octet-stream"
        } else if let type = UTType(filenameExtension: normalizedURL.pathExtension) {
            self.mediaType = type.preferredMIMEType ?? "application/octet-stream"
        } else {
            self.mediaType = "application/octet-stream"
        }
    }

    var fileSizeDescription: String {
        byteCountFormatter.string(fromByteCount: Int64(size))
    }

    var isImage: Bool {
        mediaType.lowercased().hasPrefix("image/")
    }

    static func validateDraftCollection(_ attachments: [ChatDraftAttachment]) throws {
        guard attachments.count <= Self.maxAttachmentsPerMessage else {
            throw WiredError(
                withTitle: "Attachment",
                message: "You can attach at most \(Self.maxAttachmentsPerMessage) files to a chat message."
            )
        }

        let totalSize = attachments.reduce(UInt64(0)) { partialResult, attachment in
            partialResult + attachment.size
        }

        guard totalSize <= Self.maxTotalSizeBytes else {
            throw WiredError(
                withTitle: "Attachment",
                message: "These attachments are too large together. Chat attachments are currently limited to \(byteCountFormatter.string(fromByteCount: Int64(Self.maxTotalSizeBytes))) per message."
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
