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
    
    var chat: Chat
    var searchText: String = ""
    var topOverlayInset: CGFloat = 0
    var bottomOverlayInset: CGFloat = 0
    var keyboardShowTrigger: Int = 0
    var onUserInteraction: (() -> Void)? = nil

    private let bottomAnchorID = "chat-messages-bottom-anchor"
    private let scrollIndicatorBottomInset: CGFloat = 30

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
            return filteredMessages.map(ChatDisplayItem.message)
        }

        var items: [ChatDisplayItem] = []
        var lastInsertedTimestampDate: Date?

        for message in filteredMessages {
            if shouldInsertTimestamp(before: message, lastTimestampDate: lastInsertedTimestampDate) {
                items.append(.timestamp(anchorMessageID: message.id, date: message.date))
                lastInsertedTimestampDate = message.date
            }

            items.append(.message(message))
        }

        return items
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
            List {
                if topOverlayInset > 0 {
                    Color.clear
                        .frame(height: topOverlayInset)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .timestamp(_, let date):
                        ChatInlineTimestampView(date: date)
                    case .message(let message):
                        if message.type == .say {
                            let previous = index > 0 ? displayItems[index - 1].chatMessage : nil
                            let next = index < (displayItems.count - 1) ? displayItems[index + 1].chatMessage : nil
                            let sameAsPrevious = previous?.type == .say && previous?.user.id == message.user.id
                            let sameAsNext = next?.type == .say && next?.user.id == message.user.id

                            ChatSayMessageView(
                                message: message,
                                showNickname: !sameAsPrevious,
                                showAvatar: !sameAsNext,
                                isGroupedWithNext: sameAsNext
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
                }

                Color.clear
                    .frame(height: max(bottomOverlayInset, 0.1))
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(bottomAnchorID)
            }
#if os(macOS)
            .background(
                ChatListInteractionObserver {
                    onUserInteraction?()
                }
            )
#endif
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, scrollIndicatorBottomInset, for: .scrollIndicators)
            .background(.clear)
            .environment(\.defaultMinListRowHeight, 1)
            .textSelection(.enabled)
            .frame(maxHeight: .infinity)
            .onChange(of: chat.messages.last?.id) {
                DispatchQueue.main.async {
                    if let lastMessage = chat.messages.last,
                       visibleMessageIDs.contains(lastMessage.id) {
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
                    }
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: keyboardShowTrigger) {
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
            .onChange(of: bottomOverlayInset) {
                DispatchQueue.main.async {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private func shouldInsertTimestamp(before message: ChatEvent, lastTimestampDate: Date?) -> Bool {
        guard let lastTimestampDate else { return true }
        return message.date.timeIntervalSince(lastTimestampDate) >= effectiveTimestampInterval
    }
}

private enum ChatDisplayItem: Identifiable {
    case timestamp(anchorMessageID: UUID, date: Date)
    case message(ChatEvent)

    var id: String {
        switch self {
        case .timestamp(let anchorMessageID, _):
            return "timestamp-\(anchorMessageID.uuidString)"
        case .message(let message):
            return "message-\(message.id.uuidString)"
        }
    }

    var chatMessage: ChatEvent? {
        switch self {
        case .timestamp:
            return nil
        case .message(let message):
            return message
        }
    }
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
