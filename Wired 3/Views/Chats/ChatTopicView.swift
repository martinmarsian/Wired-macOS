//
//  ChatTopicView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 25/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import SwiftUI

struct ChatTopicView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(ConnectionRuntime.self) private var runtime
    
    @State private var topicText = ""
    @State private var showTopicSheet = false
    @State private var isTopicExpanded = false
    
    var chat: Chat

    private var canSetTopic: Bool {
        runtime.hasPrivilege("wired.account.chat.set_topic")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let topic = chat.topic, topic.topic != "" {
                    Text("**Topic:** \(topic.topic) by *\(topic.nick)* at *\(topic.time.formatted())*")
                        .multilineTextAlignment(.leading)
                        .lineLimit(isTopicExpanded ? nil : 1)
                        .font(.system(size: 13))
                        .padding(10)
                        .help(chat.topic?.topic ?? "")
                        .textSelection(.enabled)
                } else {
                    Text("*No topic set*")
                        .multilineTextAlignment(.leading)
                        .lineLimit(isTopicExpanded ? nil : 1)
                        .font(.system(size: 13))
                        .padding(10)
                }
                
                Spacer()
                
                Button {
                    topicText = ""
                    showTopicSheet.toggle()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13))
                        .padding(10)
                }
                .buttonStyle(.plain)
                .disabled(!canSetTopic)
                .opacity(canSetTopic ? 1.0 : 0.45)
            }
            .sheet(isPresented: $showTopicSheet, content: {
                NavigationStack {
                    Form {
                        TextEditor(text: $topicText)
                            .frame(minHeight: 60)
                            .padding(10)
                    }
                    .navigationTitle("Set Topic")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", role: .cancel) {
                                showTopicSheet = false
                            }
                        }
                        
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                showTopicSheet = false
                                
                                if topicText != "" {
                                    Task {
                                        try await runtime.setChatTopic(chat.id, topic: topicText)
                                    }
                                }
                            }
                            .disabled(topicText == "")
                        }
                    }
                }
            })
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(.background.opacity(isTopicExpanded ? 1.0 : 0.9))
                    .stroke(.gray, style: StrokeStyle(lineWidth: 0.3 / displayScale), antialiased: true)
                    .shadow(
                        color: colorScheme == .dark
                            ? .black.opacity(0.3)
                            : .gray.opacity(0.3),
                        radius: 4
                    )
            )
            
#if os(macOS)
            .onHover { isHover in
                withAnimation(.easeInOut(duration: 0.18)) {
                    isTopicExpanded = isHover
                }
            }
#elseif os(iOS)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isTopicExpanded.toggle()
                }
            }
#endif
            .animation(.easeInOut(duration: 0.18), value: isTopicExpanded)
            .padding(8)
            .padding(.bottom, 12)
            .padding(.horizontal, 12)
#if os(macOS)
            .padding(.top, 5)
#endif
        }
        //.background(.clear)
        .backgroundEdgeFade(top: 30, bottom: 0)
    }
}
