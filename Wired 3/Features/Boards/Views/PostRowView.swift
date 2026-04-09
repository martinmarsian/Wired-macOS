//
//  PostRowView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct PostRowView: View {
    let post: BoardPost
    let highlightQuery: String?
    let canReply: Bool
    let canEdit: Bool
    let canDelete: Bool
    let canReact: Bool
    let onReply: () -> Void
    let onQuote: (String?) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleReaction: (String) -> Void
    @State private var isHoveringText = false

    private struct TextSegment: Identifiable {
        enum Kind {
            case body
            case quote
        }

        let id = UUID()
        let kind: Kind
        let text: String
    }

    private struct QuoteLine: Identifiable {
        let id = UUID()
        let level: Int
        let text: String
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateString(_ value: Date) -> String {
        dateFormatter.string(from: value)
    }

    private var renderedText: AttributedString {
        post.text.attributedWithMarkdownAndDetectedLinks(
            linkColor: .blue,
            highlightQuery: highlightQuery
        )
    }

    private func renderedText(for text: String) -> AttributedString {
        text.attributedWithMarkdownAndDetectedLinks(
            linkColor: .blue,
            highlightQuery: highlightQuery
        )
    }

    private var segments: [TextSegment] {
        var result: [TextSegment] = []
        var currentBody: [String] = []
        var currentQuote: [String] = []

        func flushBody() {
            guard !currentBody.isEmpty else { return }
            result.append(TextSegment(kind: .body, text: currentBody.joined(separator: "\n")))
            currentBody.removeAll()
        }

        func flushQuote() {
            guard !currentQuote.isEmpty else { return }
            result.append(TextSegment(kind: .quote, text: currentQuote.joined(separator: "\n")))
            currentQuote.removeAll()
        }

        for rawLine in post.text.components(separatedBy: .newlines) {
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

    private var imageURLs: [URL] {
        post.text.detectedHTTPImageURLs()
    }

    private func quoteLines(from text: String) -> [QuoteLine] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            parseQuoteLine(rawLine)
        }
    }

    private func parseQuoteLine(_ rawLine: String) -> QuoteLine? {
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
        return QuoteLine(level: level, text: content.isEmpty ? " " : content)
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
                ForEach(segments) { segment in
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
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pointerOnHover(isHovering: $isHoveringText)

            if !imageURLs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(imageURLs.prefix(3)), id: \.absoluteString) { url in
                        Link(destination: url) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 120)
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 420)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                case .failure:
                                    Label(url.lastPathComponent, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
