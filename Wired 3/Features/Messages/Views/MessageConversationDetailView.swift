//
//  MessageConversationDetailView.swift
//  Wired 3
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct MessageConversationDetailView: View {
    @Environment(ConnectionRuntime.self) private var runtime

    let conversation: MessageConversation
    var searchText: String = ""
#if os(macOS)
    @State private var isAttachmentDropTargeted = false
#endif

    private var inputText: String {
        runtime.messageDrafts[conversation.id] ?? ""
    }

    private var draftAttachments: [ChatDraftAttachment] {
        runtime.messageDraftAttachments[conversation.id] ?? []
    }

    private var inputTextBinding: Binding<String> {
        Binding(
            get: { runtime.messageDrafts[conversation.id] ?? "" },
            set: { runtime.messageDrafts[conversation.id] = $0.isEmpty ? nil : $0 }
        )
    }

    private var composerOverlayInset: CGFloat {
        let attachmentInset: CGFloat = draftAttachments.isEmpty ? 0 : 42
        #if os(macOS)
        return 58 + attachmentInset
        #else
        return 76 + attachmentInset
        #endif
    }

    private var canSend: Bool {
        runtime.canSendMessage(to: conversation)
    }

    private var placeholder: String {
        guard canSend else {
            if conversation.kind == .broadcast {
                return "No broadcast permission"
            }
            return "User unavailable"
        }
        if !draftAttachments.isEmpty {
            return conversation.kind == .broadcast ? "Broadcast message required…" : "Add a message or press Return to send…"
        }
        if conversation.kind == .broadcast {
            return "Broadcast to all online users…"
        }
        return "Type message here…"
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MessageConversationMessagesView(
                conversation: conversation,
                searchText: searchText,
                bottomOverlayInset: composerOverlayInset
            )
            .environment(runtime)

            VStack(alignment: .leading, spacing: 6) {
                if !draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(draftAttachments) { attachment in
                                ChatDraftAttachmentChipView(attachment: attachment) {
                                    runtime.removeMessageDraftAttachment(attachment, for: conversation.id)
                                }
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 8)
                    }
                }

                HStack(alignment: .top, spacing: 0) {
                    ConversationComposer(
                        text: inputTextBinding,
                        placeholder: placeholder,
                        isEnabled: canSend,
                        allowsEmptySubmit: conversation.kind == .direct && !draftAttachments.isEmpty,
                        onSend: { text in
                            do {
                                switch conversation.kind {
                                case .direct:
                                    try await runtime.sendPrivateMessage(text, in: conversation, attachments: draftAttachments)
                                    runtime.clearMessageDraftAttachments(for: conversation.id)
                                case .broadcast:
                                    try await runtime.sendBroadcastMessage(text)
                                }
                            } catch {
                                runtime.messageDrafts[conversation.id] = text
                                runtime.lastError = error
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
#if os(macOS)
                    Button {
                        NSApp.orderFrontCharacterPalette(nil)
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.title3)
                    }
                    .foregroundColor(.gray)
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
#endif
                }
            }
            .backgroundEdgeFade(top: 0, bottom: 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .contentMargins(.bottom, 15, for: .scrollIndicators)
        .background(.background)
#if os(macOS)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(isAttachmentDropTargeted ? 0.9 : 0), lineWidth: 4)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(isAttachmentDropTargeted ? 0.08 : 0))
                )
                .padding(8)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isAttachmentDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
#endif
        .onAppear {
            runtime.resetUnreads(conversation)
        }
    }

#if os(macOS)
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard conversation.kind == .direct, canSend else { return false }

        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let error {
                    Task { @MainActor in
                        runtime.lastError = error
                    }
                    return
                }

                guard let data,
                      let fileURL = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                Task { @MainActor in
                    do {
                        try runtime.addMessageDraftAttachment(fileURL, for: conversation.id)
                    } catch {
                        runtime.lastError = error
                    }
                }
            }
        }

        return true
    }
#endif
}
