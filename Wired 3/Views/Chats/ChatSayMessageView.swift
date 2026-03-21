//
//  ChatMessageView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 25/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import SwiftUI

struct ChatSayMessageView: View {
    @Environment(ConnectionRuntime.self) private var runtime
    @AppStorage("TimestampEveryMessage") var timestampEveryMessage: Bool = false
    @AppStorageCodable(key: "ChatHighlightRules", defaultValue: [])
    
    private var highlightRules: [ChatHighlightRule]
    
    var message: ChatEvent
    var showNickname: Bool = true
    var showAvatar: Bool = true
    var isGroupedWithNext: Bool = false
    var typingHandoffText: String? = nil
    var typingHandoffProgress: CGFloat = 1
    
    @State var isHovered: Bool = false
    
    var body: some View {
        let isFromYou = message.user.id == runtime.userID
        let matchedRule = matchedHighlightRule(in: message.text)
        let bubbleFillColor = matchedRule?.color.swiftUIColor
        let bubbleTextColor = matchedRule?.color.contrastTextColor
        let linkColor = bubbleTextColor ?? (isFromYou ? .white : .blue)
        
        VStack(alignment: isFromYou ? .trailing : .leading) {
            HStack(alignment: .bottom) {
                if isFromYou {
                    Spacer()
                    VStack(alignment: .trailing) {
                        if showNickname {
                            Text(message.user.nick)
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .padding(.trailing, 10)
                        }
                        Text(message.text.attributedWithDetectedLinks(linkColor: linkColor))
                            .messageBubbleStyle(
                                isFromYou: isFromYou,
                                customFillColor: bubbleFillColor,
                                customForegroundColor: bubbleTextColor,
                                showsTail: !isGroupedWithNext
                            )
                            .containerRelativeFrame(
                                .horizontal,
                                count: 4,
                                span: 3,
                                spacing: 0,
                                alignment: .trailing
                            )
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    
                    avatarView
                    
                } else {
                    avatarView
                    
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading) {
                            if showNickname {
                                Text(message.user.nick)
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                    .padding(.leading, 10)
                            }
                            Text(message.text.attributedWithDetectedLinks(linkColor: linkColor))
                                .messageBubbleStyle(
                                    isFromYou: isFromYou,
                                    customFillColor: bubbleFillColor,
                                    customForegroundColor: bubbleTextColor,
                                    showsTail: !isGroupedWithNext
                                )
                                .containerRelativeFrame(
                                    .horizontal,
                                    count: 4,
                                    span: 3,
                                    spacing: 0,
                                    alignment: .leading
                                )
                        }
                        .opacity(typingHandoffText == nil ? 1 : typingHandoffProgress)
                        .offset(y: typingHandoffText == nil ? 0 : (1 - typingHandoffProgress) * 6)

                        if let typingHandoffText {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(typingHandoffText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, 10)

                                MessagesStyleTypingBubble()
                            }
                            .opacity(1 - typingHandoffProgress)
                            .scaleEffect(1 - (typingHandoffProgress * 0.03), anchor: .bottomLeading)
                            .offset(y: typingHandoffProgress * -4)
                            .allowsHitTesting(false)
                        }
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    Spacer()
                }
            }
            
            if timestampEveryMessage {
                HoverableRelativeDateText(date: message.date)
                    .foregroundStyle(.gray)
                    .monospacedDigit()
                    .font(.caption)
                    .padding(.bottom, 3)
                    .padding(isFromYou ? .trailing : .leading, 45)
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .id(message.id)
        .animation(nil, value: showNickname)
        .animation(nil, value: showAvatar)
        .animation(nil, value: isGroupedWithNext)
        .onHover { isHover in
            isHovered = isHover
        }
    }

    private func matchedHighlightRule(in text: String) -> ChatHighlightRule? {
        let loweredText = text.lowercased()
        return highlightRules.first { rule in
            let keyword = rule.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !keyword.isEmpty else { return false }
            return loweredText.contains(keyword)
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if showAvatar {
            if let icon = Image(data: message.user.icon) {
                icon
                    .resizable()
                    .frame(width: 32, height: 32)
                    .padding(.bottom, 6)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
        } else {
            Color.clear
                .frame(width: 32, height: 32)
        }
    }
}
