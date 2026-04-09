//
//  EditThreadView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

public struct EditThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionRuntime.self) private var runtime

    let thread: BoardThread

    @State private var subject: String
    @State private var text: String = ""
    @State private var isSubmitting = false

    init(thread: BoardThread) {
        self.thread = thread
        self._subject = State(initialValue: thread.subject)
    }

    private var canSubmit: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Thread")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Subject field
            TextField("Subject", text: $subject)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Divider()

            // Composer — edge-to-edge
            MarkdownComposer(text: $text, onOptionEnter: save)
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
        .task {
            // Prefill body with currently loaded first post when available.
            if let firstPost = thread.posts.first {
                text = firstPost.text
            } else {
                try? await runtime.getPosts(forThread: thread)
                text = thread.posts.first?.text ?? ""
            }
        }
    }

    private func save() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            do {
                try await runtime.editThread(
                    uuid: thread.uuid,
                    subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try await runtime.getPosts(forThread: thread)
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
