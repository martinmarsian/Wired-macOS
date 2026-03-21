//
//  ChatMessagesView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 27/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ChatMessagesView: View {
    @Environment(ConnectionRuntime.self) private var runtime
    @AppStorage("TimestampInChat") private var timestampInChat: Bool = false
    @AppStorage("TimestampEveryMin") private var timestampEveryMin: Int = 5
    @State private var animatedNewMessageID: UUID?
    @State private var revealNewMessage = true
    @State private var displayedTypingIndicator: TypingIndicatorPresentation?
    @State private var isTypingIndicatorVisible = false
    @State private var typingHideTask: Task<Void, Never>?
    @State private var scrollToBottomTask: Task<Void, Never>?
    @State private var typingHandoffTask: Task<Void, Never>?
    @State private var isPerformingTypingHandoff = false
    @State private var typingHandoffMessageID: UUID?
    @State private var typingHandoffText: String?
    @State private var typingHandoffProgress: CGFloat = 1
    
    var chat: Chat
    var searchText: String = ""
    var topOverlayInset: CGFloat = 0
    var bottomOverlayInset: CGFloat = 0
    var keyboardShowTrigger: Int = 0
    var onUserInteraction: (() -> Void)? = nil

    private let bottomAnchorID = "chat-messages-bottom-anchor"
    private let scrollIndicatorBottomInset: CGFloat = 8

    private var effectiveTimestampInterval: TimeInterval {
        TimeInterval(max(timestampEveryMin, 1) * 60)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var filteredMessages: [ChatEvent] {
        chat.filteredMessages(matching: normalizedSearchText)
    }

    private var visibleMessageIDs: Set<UUID> {
        Set(filteredMessages.map(\.id))
    }

    private var displayItems: [ChatDisplayItem] {
        guard timestampInChat else {
            var items = transcriptMessages.map(ChatDisplayItem.message)
            if let liveSlotPresentation {
                items.append(.liveSlot(liveSlotPresentation))
            }
            return items
        }

        var items: [ChatDisplayItem] = []
        var lastInsertedTimestampDate: Date?

        for message in transcriptMessages {
            if shouldInsertTimestamp(before: message, lastTimestampDate: lastInsertedTimestampDate) {
                items.append(.timestamp(anchorMessageID: message.id, date: message.date))
                lastInsertedTimestampDate = message.date
            }

            items.append(.message(message))
        }

        if let liveSlotPresentation {
            items.append(.liveSlot(liveSlotPresentation))
        }

        return items
    }

    private var transcriptMessages: [ChatEvent] {
        guard let liveSlotMessageID else { return filteredMessages }
        return filteredMessages.filter { $0.id != liveSlotMessageID }
    }

    private var currentTypingIndicator: TypingIndicatorPresentation? {
        guard !isSearching, let text = chat.typingIndicatorText else { return nil }

        return TypingIndicatorPresentation(
            text: text,
            userID: chat.primaryTypingUser?.id
        )
    }

    private var liveSlotMessageID: UUID? {
        guard let typingHandoffMessageID,
              chat.messages.last?.id == typingHandoffMessageID,
              visibleMessageIDs.contains(typingHandoffMessageID)
        else {
            return nil
        }

        return typingHandoffMessageID
    }

    private var liveSlotPresentation: LiveSlotPresentation? {
        if let liveSlotMessageID,
           let liveMessage = filteredMessages.first(where: { $0.id == liveSlotMessageID }) {
            return .message(
                liveMessage,
                typingText: typingHandoffText,
                handoffProgress: typingHandoffProgress
            )
        }

        if let displayedTypingIndicator {
            return .typing(
                text: displayedTypingIndicator.text,
                userID: displayedTypingIndicator.userID,
                isVisible: isTypingIndicatorVisible
            )
        }

        return nil
    }
    
    var body: some View {
        if isSearching && filteredMessages.isEmpty {
            ContentUnavailableView(
                "No Matching Messages",
                systemImage: "magnifyingglass",
                description: Text("No message in \"\(chat.name)\" matches \"\(normalizedSearchText)\".")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            messagesList
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if topOverlayInset > 0 {
                        Color.clear
                            .frame(height: topOverlayInset)
                    }

                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .timestamp(_, let date):
                            ChatInlineTimestampView(date: date)
                        case .message(let message):
                            messageView(for: message, index: index)
                        case .liveSlot(let presentation):
                            liveSlotView(for: presentation, index: index)
                        }
                    }

                    Color.clear
                        .frame(height: max(bottomOverlayInset + scrollIndicatorBottomInset, 0.1))
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 10)
            }
#if os(macOS)
            .background(
                ChatListInteractionObserver {
                    onUserInteraction?()
                }
            )
#endif
            .background(.clear)
            .textSelection(.enabled)
            .frame(maxHeight: .infinity)
            .onChange(of: chat.messages.last?.id) {
                DispatchQueue.main.async {
                    if let lastMessage = chat.messages.last,
                       visibleMessageIDs.contains(lastMessage.id) {
                        let lastID = lastMessage.id
                        let bridgeTyping = displayedTypingIndicator?.userID == lastMessage.user.id && isTypingIndicatorVisible

                        if bridgeTyping {
                            beginTypingHandoff(for: lastMessage)
                            scheduleScrollToBottom(with: proxy, animated: false, delays: [0.0, 0.12])
                            animatedNewMessageID = nil
                            revealNewMessage = true
                        } else {
                            scheduleScrollToBottom(with: proxy)
                            animatedNewMessageID = lastID
                            revealNewMessage = false

                            DispatchQueue.main.asyncAfter(deadline: .now()) {
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
                    }
                }
            }
            .onAppear {
                syncTypingIndicator(animated: false)
                scheduleScrollToBottom(with: proxy)
            }
            .onChange(of: keyboardShowTrigger) {
                scheduleScrollToBottom(with: proxy)
            }
            .onChange(of: timestampInChat) {
                scheduleScrollToBottom(with: proxy)
            }
            .onChange(of: timestampEveryMin) {
                scheduleScrollToBottom(with: proxy)
            }
            .onChange(of: normalizedSearchText) {
                syncTypingIndicator(animated: true)
                scheduleScrollToBottom(with: proxy)
            }
            .onChange(of: chat.typingIndicatorText) {
                syncTypingIndicator(animated: true)
                guard !isPerformingTypingHandoff else { return }
                scheduleScrollToBottom(with: proxy, animated: true)
            }
            .onChange(of: chat.activeTypingUserIDs) {
                syncTypingIndicator(animated: true)
                guard !isPerformingTypingHandoff else { return }
                scheduleScrollToBottom(with: proxy, animated: true)
            }
            .onChange(of: bottomOverlayInset) {
                scheduleScrollToBottom(with: proxy, animated: true)
            }
            .onDisappear {
                typingHideTask?.cancel()
                scrollToBottomTask?.cancel()
                typingHandoffTask?.cancel()
            }
        }
    }

    @ViewBuilder
    private func messageView(for message: ChatEvent, index: Int) -> some View {
        if message.type == .say {
            let previous = index > 0 ? displayItems[index - 1].chatMessage : nil
            let nextItem = index < (displayItems.count - 1) ? displayItems[index + 1] : nil
            let next = nextItem?.chatMessage
            let sameAsPrevious = previous?.type == .say && previous?.user.id == message.user.id
            let sameAsNext =
                (next?.type == .say && next?.user.id == message.user.id)
                || nextItem?.continuesGrouping(forUserID: message.user.id) == true

            ChatSayMessageView(
                message: message,
                showNickname: !sameAsPrevious,
                showAvatar: !sameAsNext,
                isGroupedWithNext: sameAsNext,
                typingHandoffText: message.id == typingHandoffMessageID ? typingHandoffText : nil,
                typingHandoffProgress: message.id == typingHandoffMessageID ? typingHandoffProgress : 1
            )
            .environment(runtime)
            .scaleEffect(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0.94) : 1)
            .opacity(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0) : 1)
        }
        else if message.type == .me {
            ChatMeMessageView(message: message)
                .environment(runtime)
                .scaleEffect(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0.94) : 1)
                .opacity(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0) : 1)
        }
        else if message.type == .join || message.type == .leave || message.type == .event {
            ChatEventView(message: message)
                .environment(runtime)
                .scaleEffect(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0.94) : 1)
                .opacity(message.id == animatedNewMessageID ? (revealNewMessage ? 1 : 0) : 1)
        }
    }

    private func shouldInsertTimestamp(before message: ChatEvent, lastTimestampDate: Date?) -> Bool {
        guard let lastTimestampDate else { return true }
        return message.date.timeIntervalSince(lastTimestampDate) >= effectiveTimestampInterval
    }

    private func scheduleScrollToBottom(
        with proxy: ScrollViewProxy,
        animated: Bool = false,
        delays: [TimeInterval] = [0.0]
    ) {
        scrollToBottomTask?.cancel()
        scrollToBottomTask = Task { @MainActor in
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
                }
                guard !Task.isCancelled else { return }
                if animated {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    @MainActor
    private func syncTypingIndicator(animated: Bool) {
        let next = currentTypingIndicator

        if let next {
            typingHideTask?.cancel()
            displayedTypingIndicator = next

            guard !isTypingIndicatorVisible else { return }

            if animated {
                isTypingIndicatorVisible = false
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                        isTypingIndicatorVisible = true
                    }
                }
            } else {
                isTypingIndicatorVisible = true
            }
        } else {
            guard displayedTypingIndicator != nil else { return }

            typingHideTask?.cancel()

            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    isTypingIndicatorVisible = false
                }

                typingHideTask = Task {
                    try? await Task.sleep(for: .milliseconds(230))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if currentTypingIndicator == nil {
                            displayedTypingIndicator = nil
                        }
                    }
                }
            } else {
                isTypingIndicatorVisible = false
                displayedTypingIndicator = nil
            }
        }
    }

    @MainActor
    private func beginTypingHandoff(for message: ChatEvent) {
        typingHandoffTask?.cancel()
        typingHideTask?.cancel()

        isPerformingTypingHandoff = true
        typingHandoffMessageID = message.id
        typingHandoffText = displayedTypingIndicator?.text
        typingHandoffProgress = 0
        displayedTypingIndicator = nil
        isTypingIndicatorVisible = false

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                typingHandoffProgress = 1
            }
        }

        typingHandoffTask = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                typingHandoffText = nil
                typingHandoffProgress = 1
                isPerformingTypingHandoff = false
            }
        }
    }

    @ViewBuilder
    private func liveSlotView(for presentation: LiveSlotPresentation, index: Int) -> some View {
        let previous = index > 0 ? displayItems[index - 1].chatMessage : nil
        let isGroupedWithPrevious = previous?.type == .say && previous?.user.id == presentation.userID

        ChatIncomingLiveSlotView(
            presentation: presentation,
            user: presentation.userID.flatMap { id in
                chat.users.first(where: { $0.id == id })
            },
            isGroupedWithPrevious: isGroupedWithPrevious
        )
    }

}

private enum ChatDisplayItem: Identifiable {
    case timestamp(anchorMessageID: UUID, date: Date)
    case message(ChatEvent)
    case liveSlot(LiveSlotPresentation)

    var id: String {
        switch self {
        case .timestamp(let anchorMessageID, _):
            return "timestamp-\(anchorMessageID.uuidString)"
        case .message(let message):
            return "message-\(message.id.uuidString)"
        case .liveSlot:
            return "live-slot"
        }
    }

    var chatMessage: ChatEvent? {
        switch self {
        case .timestamp:
            return nil
        case .message(let message):
            return message
        case .liveSlot:
            return nil
        }
    }

    @MainActor
    func continuesGrouping(forUserID userID: UInt32) -> Bool {
        switch self {
        case .liveSlot(let presentation):
            switch presentation {
            case .typing(_, let typingUserID, _):
                return typingUserID == userID
            case .message(let message, _, _):
                return message.user.id == userID
            }
        case .message, .timestamp:
            return false
        }
    }
}

private enum LiveSlotPresentation {
    case typing(text: String, userID: UInt32?, isVisible: Bool)
    case message(ChatEvent, typingText: String?, handoffProgress: CGFloat)

    @MainActor
    var userID: UInt32? {
        switch self {
        case .typing(_, let userID, _):
            return userID
        case .message(let message, _, _):
            return message.user.id
        }
    }
}

private struct TypingIndicatorPresentation {
    let text: String
    let userID: UInt32?
}

private struct ChatInlineTimestampView: View {
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

private struct ChatIncomingLiveSlotView: View {
    let presentation: LiveSlotPresentation
    let user: User?
    let isGroupedWithPrevious: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            avatarView

            ZStack(alignment: .topLeading) {
                if case .message(let message, _, let handoffProgress) = presentation {
                    VStack(alignment: .leading) {
                        if !isGroupedWithPrevious {
                            Text(message.user.nick)
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .padding(.leading, 10)
                        }

                        Text(message.text.attributedWithDetectedLinks(linkColor: .blue))
                            .messageBubbleStyle(
                                isFromYou: false,
                                customFillColor: nil,
                                customForegroundColor: nil,
                                showsTail: true
                            )
                            .containerRelativeFrame(
                                .horizontal,
                                count: 4,
                                span: 3,
                                spacing: 0,
                                alignment: .leading
                            )
                    }
                    .opacity(handoffProgress)
                    .offset(y: (1 - handoffProgress) * 6)
                }

                switch presentation {
                case .typing(let text, _, let isVisible):
                    typingBody(text: text)
                        .opacity(isVisible ? 1 : 0)
                        .offset(y: isVisible ? 0 : -14)
                case .message(_, let typingText, let handoffProgress):
                    if let typingText {
                        typingBody(text: typingText)
                            .opacity(1 - handoffProgress)
                            .offset(y: handoffProgress * -14)
                    }
                }
            }
            .padding(.bottom, 8)

            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    private func typingBody(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)

            MessagesStyleTypingBubble()
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let user {
            if let icon = Image(data: user.icon) {
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
}

struct MessagesStyleTypingBubble: View {
    private let bubbleFill = Color.primary.opacity(0.10)
    private let dotColor = Color.primary.opacity(0.38)
    private let bubbleWidth: CGFloat = 54
    private let bubbleHeight: CGFloat = 30
    private let bubbleOffsetX: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(bubbleFill)
                .frame(width: bubbleWidth, height: bubbleHeight)
                .shadow(color: .black.opacity(0.035), radius: 4, y: 1)
                .offset(x: bubbleOffsetX)

            TypingDotsView(dotColor: dotColor)
                .frame(width: bubbleWidth, height: bubbleHeight)
                .offset(x: bubbleOffsetX)

            Circle()
                .fill(bubbleFill)
                .frame(width: 8, height: 8)
                .offset(x: bubbleOffsetX - 3, y: bubbleHeight - 3)

            Circle()
                .fill(bubbleFill.opacity(0.96))
                .frame(width: 5, height: 5)
                .offset(x: bubbleOffsetX - 7, y: bubbleHeight + 4.5)
        }
        .frame(width: bubbleWidth + bubbleOffsetX, height: bubbleHeight + 8, alignment: .topLeading)
    }
}

struct TypingDotsView: View {
    let dotColor: Color

    private let cycleDuration: Double = 0.9
    private let phases: [Double] = [0.0, 0.18, 0.36]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 5) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                    let motion = centeredMotion(at: time + phase)
                    let highlight = (motion + 1) / 2
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.95 + (highlight * 0.07))
                        .offset(y: -motion * 1.8)
                        .opacity(0.55 + (highlight * 0.45))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func centeredMotion(at time: Double) -> CGFloat {
        let progress = (time.truncatingRemainder(dividingBy: cycleDuration)) / cycleDuration
        return CGFloat(sin(progress * (.pi * 2)))
    }
}

#if os(macOS)
private struct ChatListInteractionObserver: NSViewRepresentable {
    let onScrollInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollInteraction: onScrollInteraction)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScrollInteraction = onScrollInteraction
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onScrollInteraction: () -> Void
        private weak var attachedView: NSView?
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(onScrollInteraction: @escaping () -> Void) {
            self.onScrollInteraction = onScrollInteraction
        }

        func attach(to view: NSView) {
            attachedView = view
            DispatchQueue.main.async { [weak self] in
                self?.refreshObservedScrollViewIfNeeded()
            }
        }

        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observedScrollView = nil
            attachedView = nil
        }

        private func refreshObservedScrollViewIfNeeded() {
            guard let view = attachedView else { return }
            let scrollView = enclosingScrollView(from: view)
            guard scrollView !== observedScrollView else { return }

            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observedScrollView = scrollView

            guard let scrollView else { return }
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.onScrollInteraction()
                }
            )
        }

        private func enclosingScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}
#endif
