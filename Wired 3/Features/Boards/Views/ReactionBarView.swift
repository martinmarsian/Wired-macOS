//
//  ReactionBarView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct ReactionBarView: View {
    let reactions: [BoardReactionSummary]
    /// Emojis that just arrived from other users — used to trigger the shake animation.
    var newEmojiSet: Set<String> = []
    let canReact: Bool
    let onToggle: (String) -> Void

    @State private var showEmojiPicker = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(reactions) { reaction in
                ReactionChipView(
                    reaction: reaction,
                    allReactions: reactions,
                    canReact: canReact,
                    isNew: newEmojiSet.contains(reaction.emoji),
                    onToggle: onToggle
                )
            }
            if canReact {
                addButton
            }
        }
        .animation(.easeInOut(duration: 0.15), value: reactions.map(\.count))
    }

    @ViewBuilder
    private var addButton: some View {
        Button { showEmojiPicker = true } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Add a reaction")
        .popover(isPresented: $showEmojiPicker, arrowEdge: .bottom) {
            EmojiPickerPopover { emoji in
                onToggle(emoji)
                showEmojiPicker = false
            }
        }
    }
}
