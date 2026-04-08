//
//  ChatHistoryConnectionList.swift
//  Wired-macOS
//

import SwiftUI
import SwiftData

struct ChatHistoryConnectionList: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var selectedConnectionKey: String?
    var searchText: String

    @State private var connections: [ConnectionEntry] = []

    struct ConnectionEntry: Identifiable, Hashable {
        var id: String { connectionKey }
        let connectionKey: String
        let displayName: String
        let lastMessageDate: Date
        let messageCount: Int
    }

    var body: some View {
        List(selection: $selectedConnectionKey) {
            ForEach(connections) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.headline)
                    HStack {
                        Text(entry.lastMessageDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.messageCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .tag(entry.connectionKey)
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Connections")
        .onAppear { refreshConnections() }
        .onChange(of: searchText) { _, _ in refreshConnections() }
    }

    private func refreshConnections() {
        do {
            let descriptor = FetchDescriptor<StoredChatMessage>(
                sortBy: [SortDescriptor(\StoredChatMessage.date, order: .reverse)]
            )
            let allMessages = try modelContext.fetch(descriptor)

            var grouped: [String: (displayName: String, lastDate: Date, count: Int)] = [:]
            for msg in allMessages {
                if !searchText.isEmpty {
                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty,
                          msg.senderNick.localizedStandardContains(query)
                          || msg.text.localizedStandardContains(query) else { continue }
                }
                if let existing = grouped[msg.connectionKey] {
                    grouped[msg.connectionKey] = (
                        displayName: existing.displayName,
                        lastDate: max(existing.lastDate, msg.date),
                        count: existing.count + 1
                    )
                } else {
                    let name = displayName(from: msg.connectionKey)
                    grouped[msg.connectionKey] = (
                        displayName: name,
                        lastDate: msg.date,
                        count: 1
                    )
                }
            }

            connections = grouped.map { key, value in
                ConnectionEntry(
                    connectionKey: key,
                    displayName: value.displayName,
                    lastMessageDate: value.lastDate,
                    messageCount: value.count
                )
            }
            .sorted { $0.lastMessageDate > $1.lastMessageDate }
        } catch {
            print("[ChatHistory] Failed to load connections:", error)
        }
    }

    private func displayName(from connectionKey: String) -> String {
        let parts = connectionKey.split(separator: "|", maxSplits: 1)
        let hostname = parts.first.map(String.init) ?? connectionKey
        let login = parts.count > 1 ? String(parts[1]) : ""

        // Try to find a matching bookmark by hostname+login for a friendly name
        if let bookmark = matchingBookmark(hostname: hostname, login: login) {
            return bookmark.name.isEmpty ? hostname : bookmark.name
        }

        if !login.isEmpty {
            return "\(hostname) (\(login))"
        }
        return hostname
    }

    private func matchingBookmark(hostname: String, login: String) -> Bookmark? {
        let descriptor = FetchDescriptor<Bookmark>()
        guard let bookmarks = try? modelContext.fetch(descriptor) else { return nil }
        return bookmarks.first {
            $0.hostname.lowercased() == hostname.lowercased()
            && $0.login.lowercased() == login.lowercased()
        }
    }
}
