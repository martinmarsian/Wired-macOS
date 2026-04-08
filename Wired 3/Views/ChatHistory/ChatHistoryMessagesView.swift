//
//  ChatHistoryMessagesView.swift
//  Wired-macOS
//

import SwiftUI
import SwiftData

struct ChatHistoryMessagesView: View {
    @Environment(\.modelContext) private var modelContext
    let connectionKey: String
    let dayKey: String
    var searchText: String

    @AppStorage("TimestampInChat") private var timestampInChat: Bool = false
    @AppStorage("TimestampEveryMin") private var timestampEveryMin = 5

    @State private var allMessages: [StoredChatMessage] = []
    @State private var displayedMessageCount: Int = 100
    @State private var isLoadingMore = false

    private var windowedMessages: [StoredChatMessage] {
        guard displayedMessageCount < allMessages.count else { return allMessages }
        return Array(allMessages.suffix(displayedMessageCount))
    }

    private var filteredMessages: [StoredChatMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windowedMessages }
        return allMessages.filter {
            $0.senderNick.localizedStandardContains(query)
            || $0.text.localizedStandardContains(query)
        }
    }

    private var hasOlderMessages: Bool {
        searchText.isEmpty && displayedMessageCount < allMessages.count
    }

    private var displayItems: [HistoryDisplayItem] {
        let messages = filteredMessages
        guard !messages.isEmpty else { return [] }

        // Pass 1: build flat list with timestamps
        var items: [HistoryDisplayItem] = []

        if timestampInChat {
            let interval = TimeInterval(max(timestampEveryMin, 1) * 60)
            var lastTimestampDate: Date?
            for msg in messages {
                if let last = lastTimestampDate {
                    if msg.date.timeIntervalSince(last) >= interval {
                        items.append(.timestamp(id: "ts-\(msg.eventID.uuidString)", date: msg.date))
                        lastTimestampDate = msg.date
                    }
                } else {
                    items.append(.timestamp(id: "ts-\(msg.eventID.uuidString)", date: msg.date))
                    lastTimestampDate = msg.date
                }
                items.append(.message(msg, showNickname: true, showAvatar: true, isGroupedWithNext: false))
            }
        } else {
            items = messages.map {
                .message($0, showNickname: true, showAvatar: true, isGroupedWithNext: false)
            }
        }

        // Pass 2: compute grouping flags
        for i in items.indices {
            guard case .message(let msg, _, _, _) = items[i],
                  ChatEventType(rawStorageValue: msg.type) == .say else { continue }

            let prevMsg = i > 0 ? items[i - 1].storedMessage : nil
            let sameAsPrev = prevMsg.map {
                ChatEventType(rawStorageValue: $0.type) == .say && $0.senderUserID == msg.senderUserID
            } ?? false

            let nextMsg = (i < items.count - 1) ? items[i + 1].storedMessage : nil
            let sameAsNext = nextMsg.map {
                ChatEventType(rawStorageValue: $0.type) == .say && $0.senderUserID == msg.senderUserID
            } ?? false

            items[i] = .message(msg, showNickname: !sameAsPrev, showAvatar: !sameAsNext, isGroupedWithNext: sameAsNext)
        }

        return items
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if hasOlderMessages {
                    loadMoreIndicator(proxy: proxy)
                }

                ForEach(displayItems, id: \.id) { item in
                    switch item {
                    case .timestamp(_, let date):
                        ChatInlineTimestampView(date: date)
                    case .message(let msg, let showNickname, let showAvatar, let isGroupedWithNext):
                        ArchiveMessageBubbleView(
                            message: msg,
                            showNickname: showNickname,
                            showAvatar: showAvatar,
                            isGroupedWithNext: isGroupedWithNext
                        )
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(formattedDayTitle)
        .onAppear { loadMessages() }
        .onChange(of: connectionKey) { _, _ in loadMessages() }
        .onChange(of: dayKey) { _, _ in loadMessages() }
    }

    private var formattedDayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let date = f.date(from: dayKey) {
            return date.formatted(date: .long, time: .omitted)
        }
        return dayKey
    }

    private func loadMessages() {
        displayedMessageCount = 100
        do {
            let key = connectionKey
            let day = dayKey
            let descriptor = FetchDescriptor<StoredChatMessage>(
                predicate: #Predicate<StoredChatMessage> {
                    $0.connectionKey == key && $0.dayKey == day
                },
                sortBy: [SortDescriptor(\StoredChatMessage.date, order: .forward)]
            )
            allMessages = try modelContext.fetch(descriptor)
        } catch {
            print("[ChatHistory] Failed to load messages:", error)
            allMessages = []
        }
    }

    @ViewBuilder
    private func loadMoreIndicator(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    loadMore(with: proxy)
                } label: {
                    Label("Load older messages", systemImage: "arrow.up.circle")
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
                loadMore(with: proxy)
            }
        }
    }

    @MainActor
    private func loadMore(with proxy: ScrollViewProxy) {
        guard hasOlderMessages, !isLoadingMore else { return }
        isLoadingMore = true
        let anchorID = displayItems.first(where: { $0.storedMessage != nil })?.id
        displayedMessageCount = min(displayedMessageCount + 100, allMessages.count)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            isLoadingMore = false
            if let anchorID {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }
}

private enum HistoryDisplayItem: Identifiable {
    case message(StoredChatMessage, showNickname: Bool, showAvatar: Bool, isGroupedWithNext: Bool)
    case timestamp(id: String, date: Date)

    var id: String {
        switch self {
        case .message(let msg, _, _, _): return msg.eventID.uuidString
        case .timestamp(let id, _): return id
        }
    }

    var storedMessage: StoredChatMessage? {
        if case .message(let msg, _, _, _) = self { return msg }
        return nil
    }
}
