//
//  ChatAttachmentViews.swift
//  Wired 3
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ChatDraftAttachmentChipView: View {
    let attachment: ChatDraftAttachment
    let onRemove: () -> Void

    private var iconName: String {
        attachment.isImage ? "photo" : "doc"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            (
                Text(attachment.fileName)
                    .font(.subheadline.weight(.medium))
                +
                Text("  \(attachment.fileSizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
            .lineLimit(1)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ChatAttachmentImageBubbleView: View {
    @Environment(ConnectionRuntime.self) private var runtime

    let attachment: ChatAttachmentDescriptor
    let isFromYou: Bool
    let showsTail: Bool

    @State private var phase: Phase = .idle

    private let maxBubbleWidth: CGFloat = 280
    private let maxBubbleHeight: CGFloat = 360
    private let placeholderSize = CGSize(width: 280, height: 190)

    enum Phase {
        case idle
        case loading
        case success(PlatformImage)
        case failure
    }

    private func resolvedSize(for image: PlatformImage) -> CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return placeholderSize }
        let ratio = natural.height / natural.width
        var width = min(natural.width, maxBubbleWidth)
        var height = width * ratio
        if height > maxBubbleHeight {
            height = maxBubbleHeight
            width = height / ratio
        }
        return CGSize(width: ceil(width), height: ceil(height))
    }

    private var currentSize: CGSize {
        if case .success(let image) = phase {
            return resolvedSize(for: image)
        }
        return placeholderSize
    }

    var body: some View {
        bubbleContent
            .frame(width: currentSize.width, height: currentSize.height)
            .mask(bubbleMask)
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            .contextMenu {
#if os(macOS)
                Button {
                    downloadAttachment()
                } label: {
                    Label("Download Image", systemImage: "square.and.arrow.down")
                }
#endif
            }
            .task(id: attachment.id) {
                await load()
            }
    }

    private var bubbleContent: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.secondary.opacity(0.18),
                    Color.secondary.opacity(0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            switch phase {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.regular)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .success(let image):
                imageView(image)
            case .failure:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                    Text(attachment.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private var bubbleMask: some View {
        MessageBubble(showsTail: showsTail)
            .fill(Color.white)
            .rotation3DEffect(isFromYou ? .degrees(0) : .degrees(180), axis: (x: 0, y: 1, z: 0))
    }

    @ViewBuilder
    private func imageView(_ image: PlatformImage) -> some View {
        let size = resolvedSize(for: image)
        Group {
#if os(iOS)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
#else
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
#endif
        }
        .frame(width: size.width, height: size.height)
    }

    @MainActor
    private func load() async {
        guard case .idle = phase else { return }
        phase = .loading

        do {
            let data = try await runtime.imageData(for: attachment)
            guard let image = AppImageCodec.platformImage(from: data) else {
                phase = .failure
                return
            }
            phase = .success(image)
        } catch {
            phase = .failure
        }
    }

#if os(macOS)
    @MainActor
    private func downloadAttachment() {
        Task {
            do {
                let data = try await runtime.downloadChatAttachmentData(attachment)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.name
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let saveURL = panel.url {
                    try data.write(to: saveURL, options: .atomic)
                }
            } catch {
                runtime.lastError = error
            }
        }
    }
#endif
}

struct ChatAttachmentFileBubbleView: View {
    @Environment(ConnectionRuntime.self) private var runtime

    let attachment: ChatAttachmentDescriptor
    let isFromYou: Bool
    let showsTail: Bool

    @State private var isSaving = false

    private var iconName: String {
        if attachment.isImage {
            return "photo"
        }

        if attachment.mediaType.lowercased().hasPrefix("audio/") {
            return "waveform"
        }

        if attachment.mediaType.lowercased().hasPrefix("video/") {
            return "film"
        }

        if attachment.mediaType.lowercased().contains("pdf") {
            return "doc.richtext"
        }

        return "doc"
    }

    var body: some View {
        HStack {
            if isFromYou { Spacer(minLength: 36) }

            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(isFromYou ? .white : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Text(attachment.fileSizeDescription)
                        .font(.caption)
                        .foregroundStyle(isFromYou ? Color.white.opacity(0.8) : .secondary)
                }

#if os(macOS)
                Button {
                    saveAttachment()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFromYou ? .white : Color.accentColor)
#endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                MessageBubble(showsTail: showsTail)
                    .fill(isFromYou ? Color.accentColor : Color.gray.opacity(0.12))
                    .rotation3DEffect(isFromYou ? .degrees(0) : .degrees(180), axis: (x: 0, y: 1, z: 0))
            )
            .foregroundStyle(isFromYou ? .white : .primary)
            .frame(maxWidth: 320, alignment: isFromYou ? .trailing : .leading)

            if !isFromYou { Spacer(minLength: 36) }
        }
    }

#if os(macOS)
    @MainActor
    private func saveAttachment() {
        guard !isSaving else { return }
        isSaving = true

        Task {
            defer { Task { @MainActor in isSaving = false } }

            do {
                let data = try await runtime.downloadChatAttachmentData(attachment)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.name
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let saveURL = panel.url {
                    try data.write(to: saveURL, options: .atomic)
                }
            } catch {
                await MainActor.run {
                    runtime.lastError = error
                }
            }
        }
    }
#endif
}
