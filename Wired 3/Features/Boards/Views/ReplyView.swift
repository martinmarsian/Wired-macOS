//
//  ReplyView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 01/03/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI
#if os(macOS)
import AppKit
private typealias ReplyPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias ReplyPlatformImage = UIImage
#endif

struct ReplyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionRuntime.self) private var runtime

    let thread: BoardThread
    let initialText: String?

    @State private var text: String  = ""
    @State private var isPosting     = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var threadAuthorIcon: ReplyPlatformImage? {
        guard let iconData = thread.posts.first?.icon else { return nil }
        return ReplyPlatformImage(data: iconData)
    }

    private var threadCreatedDateText: String {
        Self.dateFormatter.string(from: thread.postDate)
    }

    private var lastReplyDateText: String {
        Self.dateFormatter.string(from: thread.lastReplyDate ?? thread.postDate)
    }

    private var canPost: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private func authorIconView(_ icon: ReplyPlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: icon)
            .resizable()
        #else
        Image(uiImage: icon)
            .resizable()
        #endif
    }

    init(thread: BoardThread, initialText: String? = nil) {
        self.thread = thread
        self.initialText = initialText
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                if let icon = threadAuthorIcon {
                    authorIconView(icon)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Re: \(thread.subject)")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text(thread.nick)
                            .fontWeight(.medium)
                        Label(threadCreatedDateText, systemImage: "calendar")
                        Label(lastReplyDateText, systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Composer — edge-to-edge
            MarkdownComposer(text: $text, autoFocus: true, onOptionEnter: reply)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reply") { reply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPost || isPosting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .background { ResizableSheet(minWidth: 500, minHeight: 380, sizeKey: "sheet.composer") }
        .onAppear {
            if text.isEmpty, let initialText, !initialText.isEmpty {
                text = initialText
            }
        }
    }

    private func reply() {
        guard canPost, !isPosting else { return }
        isPosting = true
        Task {
            try? await runtime.addPost(toThread: thread,
                                       text: text.trimmingCharacters(in: .whitespaces))
            await MainActor.run { dismiss() }
        }
    }
}
