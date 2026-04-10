//
//  PostRowView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

private struct PostRowTextSegment: Identifiable {
    enum Kind {
        case body
        case quote
    }

    let id: String
    let kind: Kind
    let text: String
}

private struct PostRowQuoteLine: Identifiable {
    let id: String
    let level: Int
    let text: String
}

private struct PostRowContentBlock: Identifiable {
    enum Kind {
        case text(String)
        case attachment(ChatAttachmentDescriptor)
    }

    let id: String
    let kind: Kind
}

struct PostRowView: View {
    let post: BoardPost
    let highlightQuery: String?
    let availableContentWidth: CGFloat
    let canReply: Bool
    let canEdit: Bool
    let canDelete: Bool
    let canReact: Bool
    var selectedImageSource: ChatImageQuickLookSource?
    let onReply: () -> Void
    let onQuote: (String?) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleReaction: (String) -> Void
    var onSelectImage: ((ChatImageQuickLookSource) -> Void)?
    var onOpenQuickLook: ((ChatImageQuickLookSource) -> Void)?
    @State private var isHoveringText = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    private let boardImageMaxHeight: CGFloat = 900

    static func dateString(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }

    private var boardImageMaxWidth: CGFloat {
        max(280, availableContentWidth - 4)
    }

    private func renderedText(for text: String) -> AttributedString {
        text.renderingBoardAttachmentReferences().attributedWithMarkdownAndDetectedLinks(
            linkColor: .blue,
            highlightQuery: highlightQuery
        )
    }

    private func segments(for text: String) -> [PostRowTextSegment] {
        var result: [PostRowTextSegment] = []
        var currentBody: [String] = []
        var currentQuote: [String] = []
        var nextSegmentIndex = 0

        func flushBody() {
            guard !currentBody.isEmpty else { return }
            result.append(PostRowTextSegment(id: "segment-\(nextSegmentIndex)", kind: .body, text: currentBody.joined(separator: "\n")))
            nextSegmentIndex += 1
            currentBody.removeAll()
        }

        func flushQuote() {
            guard !currentQuote.isEmpty else { return }
            result.append(PostRowTextSegment(id: "segment-\(nextSegmentIndex)", kind: .quote, text: currentQuote.joined(separator: "\n")))
            nextSegmentIndex += 1
            currentQuote.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                flushBody()
                currentQuote.append(rawLine)
            } else {
                flushQuote()
                currentBody.append(rawLine)
            }
        }

        flushBody()
        flushQuote()
        return result
    }

    private var contentBlocks: [PostRowContentBlock] {
        let attachmentsByID = Dictionary(uniqueKeysWithValues: post.attachments.map { ($0.id.lowercased(), $0) })
        let pattern = #"\[([^\]]+)\]\(attachment://(?:draft/)?([0-9a-fA-F\-]+)\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [PostRowContentBlock(id: "text-0", kind: .text(post.text))]
        }

        let nsText = post.text as NSString
        let matches = regex.matches(in: post.text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return [PostRowContentBlock(id: "text-0", kind: .text(post.text))]
        }

        var blocks: [PostRowContentBlock] = []
        var renderedAttachmentIDs = Set<String>()
        var cursor = 0

        for match in matches {
            let fullRange = match.range(at: 0)
            let idRange = match.range(at: 2)

            if fullRange.location > cursor {
                let text = nsText.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
                if !text.isEmpty {
                    blocks.append(PostRowContentBlock(id: "text-\(blocks.count)", kind: .text(text)))
                }
            }

            if idRange.location != NSNotFound {
                let attachmentID = nsText.substring(with: idRange).lowercased()
                if let attachment = attachmentsByID[attachmentID] {
                    blocks.append(PostRowContentBlock(id: "attachment-\(attachmentID)-\(blocks.count)", kind: .attachment(attachment)))
                    renderedAttachmentIDs.insert(attachmentID)
                }
            }

            cursor = fullRange.location + fullRange.length
        }

        if cursor < nsText.length {
            let trailingText = nsText.substring(from: cursor)
            if !trailingText.isEmpty {
                blocks.append(PostRowContentBlock(id: "text-\(blocks.count)", kind: .text(trailingText)))
            }
        }

        for attachment in post.attachments where !renderedAttachmentIDs.contains(attachment.id.lowercased()) {
            blocks.append(PostRowContentBlock(id: "attachment-\(attachment.id.lowercased())-\(blocks.count)", kind: .attachment(attachment)))
        }

        return blocks
    }

    private var imageURLs: [URL] {
        post.text.detectedHTTPImageURLs()
    }

    private func quoteLines(from text: String) -> [PostRowQuoteLine] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, rawLine in
            parseQuoteLine(rawLine, index: index)
        }
    }

    private func parseQuoteLine(_ rawLine: String, index: Int) -> PostRowQuoteLine? {
        let chars = Array(rawLine)
        var i = 0
        while i < chars.count, chars[i].isWhitespace { i += 1 }

        var level = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == ">" else { break }
            level += 1
            i += 1
        }

        guard level > 0 else { return nil }

        let content = i < chars.count ? String(chars[i...]).trimmingCharacters(in: .whitespaces) : ""
        return PostRowQuoteLine(id: "quote-\(index)", level: level, text: content.isEmpty ? " " : content)
    }

    @ViewBuilder
    private func postIconView(_ image: BoardsPlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
        #else
        Image(uiImage: image)
            .resizable()
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Author header
            HStack(spacing: 8) {
                if let iconData = post.icon, let img = BoardsPlatformImage(data: iconData) {
                    postIconView(img)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(post.nick)
                            .font(.headline)
                        if post.isUnread {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text(Self.dateString(post.postDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let editDate = post.editDate {
                    Text("Edited \(Self.dateFormatter.string(from: editDate))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Post body
            VStack(alignment: .leading, spacing: 8) {
                ForEach(contentBlocks) { block in
                    switch block.kind {
                    case .text(let text):
                        ForEach(segments(for: text)) { segment in
                            switch segment.kind {
                            case .body:
                                Text(renderedText(for: segment.text))
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            case .quote:
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(quoteLines(from: segment.text)) { line in
                                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                                            HStack(spacing: 4) {
                                                ForEach(0..<max(1, line.level), id: \.self) { _ in
                                                    RoundedRectangle(cornerRadius: 1)
                                                        .fill(Color.secondary.opacity(0.33))
                                                        .frame(width: 2, height: 15)
                                                }
                                            }
                                            Text(renderedText(for: line.text))
                                                .font(.body)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.08))
                                )
                            }
                        }
                    case .attachment(let attachment):
                        if attachment.isImage {
                            let source = ChatImageQuickLookSource.attachment(attachment)
                            ChatAttachmentImageBubbleView(
                                attachment: attachment,
                                isFromYou: post.isOwn,
                                showsTail: false,
                                maxBubbleWidth: boardImageMaxWidth,
                                maxBubbleHeight: boardImageMaxHeight,
                                isSelected: selectedImageSource?.selectionID == source.selectionID,
                                onSelect: {
                                    onSelectImage?(source)
                                },
                                onOpenQuickLook: {
                                    onOpenQuickLook?(source)
                                }
                            )
                        } else {
                            ChatAttachmentFileBubbleView(
                                attachment: attachment,
                                isFromYou: post.isOwn,
                                showsTail: false
                            )
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pointerOnHover(isHovering: $isHoveringText)

            if !imageURLs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(imageURLs.prefix(3)), id: \.absoluteString) { url in
                        let source = ChatImageQuickLookSource.remote(url)
                        ChatRemoteImageBubbleView(
                            url: url,
                            isFromYou: post.isOwn,
                            showsTail: false,
                            maxBubbleWidth: boardImageMaxWidth,
                            maxBubbleHeight: boardImageMaxHeight,
                            isSelected: selectedImageSource?.selectionID == source.selectionID,
                            onSelect: {
                                onSelectImage?(source)
                            },
                            onOpenQuickLook: {
                                onOpenQuickLook?(source)
                            }
                        )
                        .pointerOnHover()
                    }
                }
                .padding(.top, 4)
            }

            HStack(spacing: 6) {
                if canReact || !post.reactions.isEmpty {
                    ReactionBarView(
                        reactions: post.reactions,
                        newEmojiSet: post.newReactionEmojis,
                        canReact: canReact,
                        onToggle: onToggleReaction
                    )
                }
                Spacer()
                if canReply {
                    PostActionButton(label: "Reply", icon: "arrowshape.turn.up.left", action: onReply)
                    PostActionButton(label: "Quote", icon: "quote.bubble", action: { onQuote(currentSelectedText()) })
                }
                if canEdit {
                    PostActionButton(label: "Edit", icon: "pencil", action: onEdit)
                }
                if canDelete {
                    PostActionButton(label: "Delete", icon: "trash", destructive: true, action: onDelete)
                }
            }
            .padding(.top, 12)
        }
        .padding(.vertical, 12)
        .contextMenu {
            if canReply {
                Button("Reply") { onReply() }
                Button("Quote") { onQuote(currentSelectedText()) }
                Divider()
            }
            if canEdit {
                Button("Edit Post") { onEdit() }
            }
            if canDelete {
                Button("Delete Post", role: .destructive) { onDelete() }
            }
        }
    }

    private func currentSelectedText() -> String? {
        #if os(macOS)
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let ns = textView.string as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
        #else
        return nil
        #endif
    }
}

private extension String {
    func renderingBoardAttachmentReferences() -> String {
        let pattern = #"\[([^\]]+)\]\(attachment://(?:draft/[0-9a-fA-F\-]+|[0-9a-fA-F\-]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "$1")
    }
}
