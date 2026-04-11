//
//  NewThreadView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 01/03/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

private enum NewThreadField {
    case subject
}

struct NewThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionRuntime.self) private var runtime

    let board: Board

    @State private var subject: String = ""
    @State private var text: String    = ""
    @State private var attachments: [ComposerAttachmentItem] = []
    @State private var isPosting       = false
    @FocusState private var focusedField: NewThreadField?

    private var canPost: Bool {
        !subject.trimmingCharacters(in: .whitespaces).isEmpty &&
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Thread")
                        .font(.headline)
                    Text(board.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Subject field
            TextField("Subject", text: $subject)
                .focused($focusedField, equals: .subject)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Divider()

            // Composer — edge-to-edge
            MarkdownComposer(
                text: $text,
                attachments: $attachments,
                autoFocus: false,
                onOptionEnter: post,
                onAttachmentError: { runtime.lastError = $0 }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Post") { post() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPost || isPosting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .background { ResizableSheet(minWidth: 500, minHeight: 380, sizeKey: "sheet.composer") }
        .onAppear { focusedField = .subject }
    }

    private func post() {
        guard canPost, !isPosting else { return }
        isPosting = true
        Task {
            try? await runtime.addThread(toBoard: board,
                                         subject: subject.trimmingCharacters(in: .whitespaces),
                                         text: text.trimmingCharacters(in: .whitespaces),
                                         attachments: attachments)
            await MainActor.run { dismiss() }
        }
    }
}
