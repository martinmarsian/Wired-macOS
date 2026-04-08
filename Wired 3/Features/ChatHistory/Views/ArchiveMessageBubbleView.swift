//
//  ArchiveMessageBubbleView.swift
//  Wired-macOS
//

import SwiftUI

struct ArchiveMessageBubbleView: View {
    let message: StoredChatMessage
    var showNickname: Bool = true
    var showAvatar: Bool = true
    var isGroupedWithNext: Bool = false

    @AppStorage("TimestampEveryMessage") private var timestampEveryMessage: Bool = false
    @AppStorageCodable(key: "ChatHighlightRules", defaultValue: [])
    private var highlightRules: [ChatHighlightRule]

    private var trimmedText: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var primaryImageURL: URL? {
        message.text.detectedHTTPImageURLs().first
    }

    private var isImageOnlyMessage: Bool {
        guard let url = primaryImageURL else { return false }
        return trimmedText == url.absoluteString
    }

    private var isEmojiOnlyMessage: Bool {
        primaryImageURL == nil && trimmedText.isShortEmojiOnly
    }

    private var shouldShowTextBubble: Bool {
        !isImageOnlyMessage
    }

    var body: some View {
        let isFromYou = message.isFromCurrentUser
        let eventType = ChatEventType(rawStorageValue: message.type)

        switch eventType {
        case .say:
            sayMessageView(isFromYou: isFromYou)
        case .me:
            meMessageView
        case .join:
            eventTextView("**\(message.senderNick)** joined")
        case .leave:
            eventTextView("**\(message.senderNick)** left")
        case .event:
            eventTextView(message.text)
        }
    }

    @ViewBuilder
    private func sayMessageView(isFromYou: Bool) -> some View {
        let matchedRule = highlightRules.first { rule in
            let keyword = rule.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !keyword.isEmpty else { return false }
            return message.text.lowercased().contains(keyword)
        }
        let bubbleFillColor = matchedRule?.color.swiftUIColor
        let bubbleTextColor = matchedRule?.color.contrastTextColor
        let linkColor = bubbleTextColor ?? (isFromYou ? .white : .blue)

        VStack(alignment: isFromYou ? .trailing : .leading) {
            HStack(alignment: .bottom) {
                if isFromYou {
                    Spacer()
                    VStack(alignment: .trailing) {
                        if showNickname {
                            Text(message.senderNick)
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .padding(.trailing, 10)
                        }
                        messageContentStack(
                            isFromYou: isFromYou,
                            linkColor: linkColor,
                            bubbleFillColor: bubbleFillColor,
                            bubbleTextColor: bubbleTextColor
                        )
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    avatarView
                } else {
                    avatarView
                    VStack(alignment: .leading) {
                        if showNickname {
                            Text(message.senderNick)
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .padding(.leading, 10)
                        }
                        messageContentStack(
                            isFromYou: isFromYou,
                            linkColor: linkColor,
                            bubbleFillColor: bubbleFillColor,
                            bubbleTextColor: bubbleTextColor
                        )
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    Spacer()
                }
            }

            if timestampEveryMessage {
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.gray)
                    .monospacedDigit()
                    .font(.caption)
                    .padding(.bottom, 3)
                    .padding(isFromYou ? .trailing : .leading, 45)
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    @ViewBuilder
    private func messageContentStack(
        isFromYou: Bool,
        linkColor: Color,
        bubbleFillColor: Color?,
        bubbleTextColor: Color?
    ) -> some View {
        VStack(alignment: isFromYou ? .trailing : .leading, spacing: 6) {
            if isEmojiOnlyMessage {
                Text(trimmedText)
                    .font(.system(size: 52))
                    .padding(.horizontal, 4)
            } else if shouldShowTextBubble {
                Text(message.text.attributedWithDetectedLinks(linkColor: linkColor))
                    .messageBubbleStyle(
                        isFromYou: isFromYou,
                        customFillColor: bubbleFillColor,
                        customForegroundColor: bubbleTextColor,
                        showsTail: primaryImageURL == nil && !isGroupedWithNext
                    )
                    .containerRelativeFrame(
                        .horizontal,
                        count: 4,
                        span: 3,
                        spacing: 0,
                        alignment: isFromYou ? .trailing : .leading
                    )
            }

            if let primaryImageURL {
                ChatRemoteImageBubbleView(
                    url: primaryImageURL,
                    isFromYou: isFromYou,
                    showsTail: !isGroupedWithNext
                )
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if showAvatar {
            if let iconData = message.senderIcon, let icon = Image(data: iconData) {
                icon
                    .resizable()
                    .frame(width: 32, height: 32)
                    .padding(.bottom, 6)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        } else {
            Color.clear
                .frame(width: 32, height: 32)
                .padding(.bottom, 6)
        }
    }

    private var meMessageView: some View {
        HStack {
            Spacer()
            (
                Text("**\(message.senderNick)** ")
                +
                Text(message.text.attributedWithDetectedLinks(linkColor: .blue))
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.gray)
            .font(.caption)
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    private func eventTextView(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(LocalizedStringKey(text))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.gray)
                .font(.caption)
            Spacer()
        }
        .listRowSeparator(.hidden)
    }
}
