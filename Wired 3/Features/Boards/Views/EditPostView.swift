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
    @State private var isSubmitting = false

    init(post: BoardPost, thread: BoardThread?) {
        self.post = post
        self.thread = thread
        self._text = State(initialValue: post.text)
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
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
            MarkdownComposer(text: $text, autoFocus: true, onOptionEnter: save)
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
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
