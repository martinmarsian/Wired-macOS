//
//  MessageConversationMessagesView.swift
//  Wired 3
//

import SwiftUI

struct MessageConversationMessagesView: View {
    @Environment(ConnectionRuntime.self) private var runtime
    @AppStorage("TimestampInChat") private var timestampInChat: Bool = false
    @AppStorage("TimestampEveryMin") private var timestampEveryMin: Int = 5
    @AppStorage("ChatMaxDisplayedMessages") private var maxDisplayedMessages: Int = 100
    let conversation: MessageConversation
    var searchText: String = ""
    @State private var animatedNewMessageID: UUID?
    @State private var revealNewMessage = true
    @State private var displayedMessageCount: Int = 100
    @State private var isLoadingMore = false
    var bottomOverlayInset: CGFloat = 0

    private let bottomAnchorID = "message-conversation-bottom-anchor"

    private var effectiveTimestampInterval: TimeInterval {
        TimeInterval(max(timestampEveryMin, 1) * 60)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var windowedMessages: [MessageEvent] {
        let all = conversation.messages
        guard displayedMessageCount < all.count else { return all }
        return Array(all.suffix(displayedMessageCount))
    }

    private var hasOlderMessages: Bool {
        !isSearching && displayedMessageCount < conversation.messages.count
    }

    private var filteredMessages: [MessageEvent] {
        if isSearching {
            return conversation.filteredMessages(matching: normalizedSearchText)
        }
        return windowedMessages
    }

    private var displayItems: [MessageConversationDisplayItem] {
        var items: [MessageConversationDisplayItem] = []

        if timestampInChat {
            var lastInsertedTimestampDate: Date?

            for message in filteredMessages {
                if shouldInsertTimestamp(before: message, lastTimestampDate: lastInsertedTimestampDate) {
                    items.append(.timestamp(anchorMessageID: message.id, date: message.date))
                    lastInsertedTimestampDate = message.date
                }

                items.append(
                    .message(
                        message,
                        showNickname: true,
                        showAvatar: true,
                        isGroupedWithNext: false
                    )
                )
            }
        } else {
            items = filteredMessages.map {
                .message($0, showNickname: true, showAvatar: true, isGroupedWithNext: false)
            }
        }

        for index in items.indices {
            guard case .message(let message, _, _, _) = items[index] else { continue }

            let previous = index > 0 ? items[index - 1].messageEvent : nil
            let sameAsPrevious = previous.map { isSameSender($0, as: message) } ?? false

            let next = index < (items.count - 1) ? items[index + 1].messageEvent : nil
            let sameAsNext = next.map { isSameSender($0, as: message) } ?? false

            items[index] = .message(
                message,
                showNickname: !sameAsPrevious,
                showAvatar: !sameAsNext,
                isGroupedWithNext: sameAsNext
            )
        }

        return items
    }

    var body: some View {
        Group {
            if isSearching && filteredMessages.isEmpty {
                ContentUnavailableView(
                    "No Matching Messages",
                    systemImage: "magnifyingglass",
                    description: Text("No message in \"\(conversation.title)\" matches \"\(normalizedSearchText)\".")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messagesList
            }
        }
        .onChange(of: conversation.id) {
            displayedMessageCount = maxDisplayedMessages
        }
        .onChange(of: maxDisplayedMessages) { _, newMax in
            if displayedMessageCount < newMax {
                displayedMessageCount = newMax
            }
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hasOlderMessages {
                        loadMoreIndicatorView(proxy: proxy)
                    }

                    ForEach(displayItems, id: \.id) { item in
                        switch item {
                        case .timestamp(_, let date):
                            MessageInlineTimestampView(date: date)
                        case .message(let message, let showNickname, let showAvatar, let isGroupedWithNext):
                            MessageBubbleRow(
                                message: message,
                                currentUserID: runtime.userID,
                                showNickname: showNickname,
                                showAvatar: showAvatar,
                                isGroupedWithNext: isGroupedWithNext
                            )
                                .scaleEffect(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0.94) : 1)
                                .opacity(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0) : 1)
                                .id(item.id)
                        }
                    }

                    Color.clear
                        .frame(height: max(bottomOverlayInset, 0.1))
                        .id(bottomAnchorID)
                }
            }
            .background(.clear)
            .textSelection(.enabled)
            .frame(maxHeight: .infinity)
            .onChange(of: conversation.messages.last?.id) {
                guard let lastMessage = conversation.messages.last else { return }
                let isVisible = !isSearching || lastMessage.matchesSearch(normalizedSearchText)
                guard isVisible else { return }

                DispatchQueue.main.async {
                    let lastID = lastMessage.id
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
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onAppear {
                displayedMessageCount = maxDisplayedMessages
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
            .onChange(of: normalizedSearchText) {
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

    @ViewBuilder
    private func loadMoreIndicatorView(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    loadMoreMessages(with: proxy)
                } label: {
                    Label("Load older messages", systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loadMoreMessages(with: proxy)
            }
        }
    }

    @MainActor
    private func loadMoreMessages(with proxy: ScrollViewProxy) {
        guard hasOlderMessages, !isLoadingMore else { return }
        isLoadingMore = true

        let anchorID = displayItems.first(where: { $0.messageEvent != nil })?.id
        displayedMessageCount = min(displayedMessageCount + 100, conversation.messages.count)

        DispatchQueue.main.async {
            if let anchorID {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            isLoadingMore = false
        }
    }
}

private struct MessageBubbleRow: View {
    @AppStorage("TimestampEveryMessage") private var timestampEveryMessage: Bool = false

    let message: MessageEvent
    let currentUserID: UInt32
    let showNickname: Bool
    let showAvatar: Bool
    let isGroupedWithNext: Bool

    private var primaryImageURL: URL? {
        message.cachedPrimaryHTTPImageURL
    }

    private var imageAttachments: [ChatAttachmentDescriptor] {
        message.attachments.filter(\.isImage)
    }

    private var fileAttachments: [ChatAttachmentDescriptor] {
        message.attachments.filter { !$0.isImage }
    }

    private var trimmedMessageText: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isImageOnlyMessage: Bool {
        guard let primaryImageURL else { return false }
        return trimmedMessageText == primaryImageURL.absoluteString
    }

    private var shouldShowTextBubble: Bool {
        !trimmedMessageText.isEmpty && !isImageOnlyMessage
    }

    private var isEmojiOnlyMessage: Bool {
        primaryImageURL == nil && trimmedMessageText.isShortEmojiOnly
    }

    var body: some View {
        let isFromYou = message.isFromCurrentUser || message.senderUserID == currentUserID
        let linkColor: Color = isFromYou ? .white : .blue

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
                        messageContentStack(isFromYou: isFromYou, linkColor: linkColor)
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    .alignmentGuide(.bottom) { d in isEmojiOnlyMessage ? d[VerticalAlignment.center] : d[.bottom] }
                    avatarView
                        .alignmentGuide(.bottom) { d in isEmojiOnlyMessage ? d[VerticalAlignment.center] : d[.bottom] }
                } else {
                    avatarView
                        .alignmentGuide(.bottom) { d in isEmojiOnlyMessage ? d[VerticalAlignment.center] : d[.bottom] }
                    VStack(alignment: .leading) {
                        if showNickname {
                            Text(message.senderNick)
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .padding(.leading, 10)
                        }
                        messageContentStack(isFromYou: isFromYou, linkColor: linkColor)
                    }
                    .padding(.bottom, isGroupedWithNext ? 2 : 8)
                    .alignmentGuide(.bottom) { d in isEmojiOnlyMessage ? d[VerticalAlignment.center] : d[.bottom] }
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
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func messageContentStack(isFromYou: Bool, linkColor: Color) -> some View {
        VStack(alignment: isFromYou ? .trailing : .leading, spacing: 6) {
            if isEmojiOnlyMessage {
                Text(trimmedMessageText)
                    .font(.system(size: 52))
                    .padding(.horizontal, 4)
            } else if shouldShowTextBubble {
                Text(message.text.attributedWithDetectedLinks(linkColor: linkColor))
                    .messageBubbleStyle(
                        isFromYou: isFromYou,
                        showsTail: primaryImageURL == nil && imageAttachments.isEmpty && fileAttachments.isEmpty && !isGroupedWithNext
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
                    showsTail: imageAttachments.isEmpty && fileAttachments.isEmpty && !isGroupedWithNext
                )
            }

            ForEach(Array(imageAttachments.enumerated()), id: \.element.id) { index, attachment in
                ChatAttachmentImageBubbleView(
                    attachment: attachment,
                    isFromYou: isFromYou,
                    showsTail: index == imageAttachments.count - 1 && fileAttachments.isEmpty && !isGroupedWithNext
                )
            }

            ForEach(Array(fileAttachments.enumerated()), id: \.element.id) { index, attachment in
                ChatAttachmentFileBubbleView(
                    attachment: attachment,
                    isFromYou: isFromYou,
                    showsTail: index == fileAttachments.count - 1 && !isGroupedWithNext
                )
            }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if showAvatar {
            if let icon = message.senderIcon, let image = Image(data: icon) {
                image
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
}

private enum MessageConversationDisplayItem: Identifiable {
    case timestamp(anchorMessageID: UUID, date: Date)
    case message(MessageEvent, showNickname: Bool, showAvatar: Bool, isGroupedWithNext: Bool)

    var id: String {
        switch self {
        case .timestamp(let anchorMessageID, _):
            return "timestamp-\(anchorMessageID.uuidString)"
        case .message(let message, _, _, _):
            return "message-\(message.id.uuidString)"
        }
    }

    var messageEvent: MessageEvent? {
        switch self {
        case .timestamp:
            return nil
        case .message(let message, _, _, _):
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
    }
}
