//
//  MessageConversationMessagesView.swift
//  Wired 3
//

import SwiftUI

struct MessageConversationMessagesView: View {
    @Environment(ConnectionRuntime.self) private var runtime
    @AppStorage("TimestampInChat") private var timestampInChat: Bool = false
    @AppStorage("TimestampEveryMin") private var timestampEveryMin: Int = 5
    let conversation: MessageConversation
    @State private var animatedNewMessageID: UUID?
    @State private var revealNewMessage = true
    var bottomOverlayInset: CGFloat = 0

    private let bottomAnchorID = "message-conversation-bottom-anchor"
    
    private var effectiveTimestampInterval: TimeInterval {
        TimeInterval(max(timestampEveryMin, 1) * 60)
    }

    private var displayItems: [MessageConversationDisplayItem] {
        guard timestampInChat else {
            return conversation.messages.map(MessageConversationDisplayItem.message)
        }

        var items: [MessageConversationDisplayItem] = []
        var lastInsertedTimestampDate: Date?

        for message in conversation.messages {
            if shouldInsertTimestamp(before: message, lastTimestampDate: lastInsertedTimestampDate) {
                items.append(.timestamp(anchorMessageID: message.id, date: message.date))
                lastInsertedTimestampDate = message.date
            }

            items.append(.message(message))
        }

        return items
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .timestamp(_, let date):
                        MessageInlineTimestampView(date: date)
                    case .message(let message):
                        let previous = index > 0 ? displayItems[index - 1].messageEvent : nil
                        let next = index < (displayItems.count - 1) ? displayItems[index + 1].messageEvent : nil
                        let sameAsPrevious = previous.map { isSameSender($0, as: message) } ?? false
                        let sameAsNext = next.map { isSameSender($0, as: message) } ?? false

                        MessageBubbleRow(
                            message: message,
                            currentUserID: runtime.userID,
                            showNickname: !sameAsPrevious,
                            showAvatar: !sameAsNext,
                            isGroupedWithNext: sameAsNext
                        )
                            .scaleEffect(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0.94) : 1)
                            .opacity(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0) : 1)
                            .id(message.id)
                    }
                }

                Color.clear
                    .frame(height: max(bottomOverlayInset, 0.1))
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(bottomAnchorID)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .environment(\.defaultMinListRowHeight, 1)
            .textSelection(.enabled)
            .frame(maxHeight: .infinity)
            .onChange(of: conversation.messages.count) {
                DispatchQueue.main.async {
                    if let lastID = conversation.messages.last?.id {
                        animatedNewMessageID = lastID
                        revealNewMessage = false
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                revealNewMessage = true
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if animatedNewMessageID == lastID {
                                animatedNewMessageID = nil
                            }
                        }
                    }
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: timestampInChat) {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: timestampEveryMin) {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private func shouldInsertTimestamp(before message: MessageEvent, lastTimestampDate: Date?) -> Bool {
        guard let lastTimestampDate else { return true }
        return message.date.timeIntervalSince(lastTimestampDate) >= effectiveTimestampInterval
    }

    private func senderKey(for message: MessageEvent) -> String {
        if message.isFromCurrentUser || message.senderUserID == runtime.userID {
            return "me"
        }
        if let senderUserID = message.senderUserID {
            return "id:\(senderUserID)"
        }
        return "nick:\(message.senderNick)"
    }

    private func isSameSender(_ lhs: MessageEvent, as rhs: MessageEvent) -> Bool {
        senderKey(for: lhs) == senderKey(for: rhs)
    }
}

private struct MessageBubbleRow: View {
    @AppStorage("TimestampEveryMessage") private var timestampEveryMessage: Bool = false

    let message: MessageEvent
    let currentUserID: UInt32
    let showNickname: Bool
    let showAvatar: Bool
    let isGroupedWithNext: Bool

    var body: some View {
        let isFromYou = message.isFromCurrentUser || message.senderUserID == currentUserID
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
                        Text(message.text.attributedWithDetectedLinks(linkColor: .white))
                            .messageBubbleStyle(isFromYou: true, showsTail: !isGroupedWithNext)
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
                    VStack(alignment: .leading) {
                        if showNickname {
                            Text(message.senderNick)
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .padding(.leading, 10)
                        }
                        Text(message.text.attributedWithDetectedLinks(linkColor: .blue))
                            .messageBubbleStyle(isFromYou: false, showsTail: !isGroupedWithNext)
                            .containerRelativeFrame(
                                .horizontal,
                                count: 4,
                                span: 3,
                                spacing: 0,
                                alignment: .leading
                            )
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    Spacer()
                }
            }

            if timestampEveryMessage {
                RelativeDateText(date: message.date)
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
    private var avatarView: some View {
        if showAvatar {
            if let icon = message.senderIcon, let image = Image(data: icon) {
                image
                    .resizable()
                    .frame(width: 32, height: 32)
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

private enum MessageConversationDisplayItem: Identifiable {
    case timestamp(anchorMessageID: UUID, date: Date)
    case message(MessageEvent)

    var id: String {
        switch self {
        case .timestamp(let anchorMessageID, _):
            return "timestamp-\(anchorMessageID.uuidString)"
        case .message(let message):
            return "message-\(message.id.uuidString)"
        }
    }

    var messageEvent: MessageEvent? {
        switch self {
        case .timestamp:
            return nil
        case .message(let message):
            return message
        }
    }
}

private struct MessageInlineTimestampView: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.06))
                )

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}
