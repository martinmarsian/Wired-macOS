//
//  MoveThreadView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

public struct MoveThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionRuntime.self) private var runtime

    let thread: BoardThread

    @State private var destinationPath: String
    @State private var isSubmitting = false

    init(thread: BoardThread) {
        self.thread = thread
        self._destinationPath = State(initialValue: thread.boardPath)
    }

    private var availableBoards: [Board] {
        var result: [Board] = []
        func walk(_ boards: [Board]) {
            for board in boards {
                result.append(board)
                if let children = board.children {
                    walk(children)
                }
            }
        }
        walk(runtime.boards)
        return result
    }

    private var canSubmit: Bool {
        !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && destinationPath != thread.boardPath
            && !isSubmitting
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Move Thread")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                TextField("Destination Path", text: $destinationPath)
                Picker("Destination", selection: $destinationPath) {
                    ForEach(availableBoards) { board in
                        Text(board.path).tag(board.path)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") { move() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding()
        }
        .frame(width: 560, height: 280)
    }

    private func move() {
        isSubmitting = true
        Task {
            do {
                try await runtime.moveThread(
                    uuid: thread.uuid,
                    newBoardPath: destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
                )
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
