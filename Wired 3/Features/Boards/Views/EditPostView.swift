//
//  EditPostView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

public struct EditPostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionRuntime.self) private var runtime

    let post: BoardPost
    let thread: BoardThread?

    @State private var text: String
    @State private var attachments: [ComposerAttachmentItem]
    @State private var isSubmitting = false

    private let initialAttachmentReferenceKeys: [String]

    init(post: BoardPost, thread: BoardThread?) {
        self.post = post
        self.thread = thread
        self._text = State(initialValue: post.text)
        self._attachments = State(initialValue: post.attachments.map(ComposerAttachmentItem.remote))
        self.initialAttachmentReferenceKeys = post.attachments.map { "remote:\($0.id.lowercased())" }
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    private var attachmentReferencesChanged: Bool {
        attachments.map(Self.attachmentReferenceKey(for:)) != initialAttachmentReferenceKeys
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Post")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Composer — edge-to-edge
            MarkdownComposer(
                text: $text,
                attachments: $attachments,
                autoFocus: true,
                onOptionEnter: save,
                onAttachmentError: { runtime.lastError = $0 }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .background { ResizableSheet(minWidth: 500, minHeight: 380, sizeKey: "sheet.composer") }
    }

    private func save() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            do {
                try await runtime.editPost(
                    uuid: post.uuid,
                    subject: thread?.subject ?? "",
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    attachments: attachments,
                    sendAttachmentIDs: attachmentReferencesChanged
                )
                if let thread {
                    try await runtime.getPosts(forThread: thread)
                }
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    runtime.lastError = error
                    isSubmitting = false
                }
            }
        }
    }

    private static func attachmentReferenceKey(for attachment: ComposerAttachmentItem) -> String {
        switch attachment {
        case .local(let draft):
            return "local:\(draft.id.uuidString.lowercased())"
        case .remote(let descriptor):
            return "remote:\(descriptor.id.lowercased())"
        }
    }
}
