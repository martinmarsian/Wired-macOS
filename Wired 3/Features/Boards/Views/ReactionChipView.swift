//
//  ReactionChipView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

public struct ReactionChipView: View {
    let reaction: BoardReactionSummary
    /// Full reaction list passed so the hover popover can show all reactions at once.
    let allReactions: [BoardReactionSummary]
    let canReact: Bool
    /// Set to `true` for one render cycle when this emoji just arrived from another user.
    var isNew: Bool = false
    let onToggle: (String) -> Void

    @State private var showPopover = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var shakeOffset: CGFloat = 0

    public var body: some View {
        Button { onToggle(reaction.emoji) } label: {
            HStack(spacing: 4) {
                Text(reaction.emoji)
                    .font(.system(size: 14))
                Text("\(reaction.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reaction.isOwn ? Color.white : Color.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(reaction.isOwn ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        reaction.isOwn ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!canReact)
        .offset(x: shakeOffset)
        .onChange(of: isNew) { _, newVal in
            if newVal { performShake() }
        }
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    showPopover = true
                }
            } else {
                showPopover = false
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ReactionSummaryPopover(reactions: allReactions)
        }
        .contextMenu {
            if canReact {
                Button(reaction.isOwn ? "Remove your reaction" : "React with \(reaction.emoji)") {
                    onToggle(reaction.emoji)
                }
            }
        }
    }

    /// Brief left-right wiggle to signal a newly arrived reaction.
    private func performShake() {
        let step = 0.07
        withAnimation(.easeInOut(duration: step)) { shakeOffset = -4 }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 1) {
            withAnimation(.easeInOut(duration: step)) { shakeOffset =  4 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 2) {
            withAnimation(.easeInOut(duration: step)) { shakeOffset = -3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 3) {
            withAnimation(.easeInOut(duration: step)) { shakeOffset =  2 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step * 4) {
            withAnimation(.easeInOut(duration: step)) { shakeOffset =  0 }
        }
    }
}

private struct ReactionSummaryPopover: View {
    let reactions: [BoardReactionSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reactions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(reactions) { reaction in
                        HStack(alignment: .top, spacing: 10) {
                            Text(reaction.emoji)
                                .font(.title3)
                                .frame(width: 28, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(reaction.count) reaction\(reaction.count == 1 ? "" : "s")")
                                        .font(.subheadline.weight(.medium))
                                    if reaction.isOwn {
                                        Circle()
                                            .fill(Color.accentColor)
                                            .frame(width: 5, height: 5)
                                    }
                                }
                                if !reaction.nicks.isEmpty {
                                    Text(reaction.nicks.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)

                        if reaction.id != reactions.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 230)
        .padding(.bottom, 6)
    }
}
