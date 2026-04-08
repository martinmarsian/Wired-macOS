//
//  ChatHistoryDayList.swift
//  Wired-macOS
//

import SwiftUI
import SwiftData

struct ChatHistoryDayList: View {
    @Environment(\.modelContext) private var modelContext
    let connectionKey: String
    @Binding var selectedDayKey: String?
    var searchText: String

    @State private var days: [DayEntry] = []

    struct DayEntry: Identifiable, Hashable {
        var id: String { dayKey }
        let dayKey: String
        let displayDate: String
        let messageCount: Int
    }

    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        List(selection: $selectedDayKey) {
            ForEach(days) { entry in
                HStack {
                    Text(entry.displayDate)
                    Spacer()
                    Text("\(entry.messageCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .font(.callout)
                }
                .tag(entry.dayKey)
            }
        }
        .navigationTitle("Days")
        .onAppear { refreshDays() }
        .onChange(of: connectionKey) { _, _ in refreshDays() }
        .onChange(of: searchText) { _, _ in refreshDays() }
    }

    private func refreshDays() {
        do {
            let key = connectionKey
            let descriptor = FetchDescriptor<StoredChatMessage>(
                predicate: #Predicate<StoredChatMessage> { $0.connectionKey == key },
                sortBy: [SortDescriptor(\StoredChatMessage.date, order: .forward)]
            )
            let messages = try modelContext.fetch(descriptor)

            var grouped: [String: Int] = [:]
            for msg in messages {
                if !searchText.isEmpty {
                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty,
                          msg.senderNick.localizedStandardContains(query)
                          || msg.text.localizedStandardContains(query) else { continue }
                }
                grouped[msg.dayKey, default: 0] += 1
            }

            days = grouped.map { dayKey, count in
                let displayDate: String
                if let date = Self.dayKeyParser.date(from: dayKey) {
                    displayDate = date.formatted(date: .long, time: .omitted)
                } else {
                    displayDate = dayKey
                }
                return DayEntry(dayKey: dayKey, displayDate: displayDate, messageCount: count)
            }
            .sorted { $0.dayKey < $1.dayKey }
        } catch {
            print("[ChatHistory] Failed to load days:", error)
        }
    }
}
