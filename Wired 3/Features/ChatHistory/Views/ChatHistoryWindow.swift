//
//  ChatHistoryWindow.swift
//  Wired-macOS
//

import SwiftUI
import SwiftData

struct ChatHistoryWindow: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedConnectionKey: String?
    @State private var selectedDayKey: String?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            ChatHistoryConnectionList(
                selectedConnectionKey: $selectedConnectionKey,
                searchText: searchText
            )
        } content: {
            if let selectedConnectionKey {
                ChatHistoryDayList(
                    connectionKey: selectedConnectionKey,
                    selectedDayKey: $selectedDayKey,
                    searchText: searchText
                )
            } else {
                ContentUnavailableView(
                    "Select a Connection",
                    systemImage: "server.rack",
                    description: Text("Choose a connection to browse its chat history.")
                )
            }
        } detail: {
            if let selectedConnectionKey, let selectedDayKey {
                ChatHistoryMessagesView(
                    connectionKey: selectedConnectionKey,
                    dayKey: selectedDayKey,
                    searchText: searchText
                )
            } else {
                ContentUnavailableView(
                    "Select a Day",
                    systemImage: "calendar",
                    description: Text("Choose a day to view its messages.")
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search messages...")
        .wiredSearchFieldFocus()
        .onChange(of: selectedConnectionKey) { _, _ in
            selectedDayKey = nil
        }
    }
}
