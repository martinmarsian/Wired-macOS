//
//  PostsDetailView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct PostsDetailView: View {
    @Environment(ConnectionRuntime.self) private var runtime
    private let bottomAnchorID = "posts-bottom-anchor"

    let boardPath: String
    let threadUUID: String
    let highlightQuery: String?
    @State private var postToEdit: BoardPost?
    @State private var postToDelete: BoardPost?
    @State private var replyComposerContext: ReplyComposerContext?
    @State private var selectedImageSource: ChatImageQuickLookSource?
#if os(macOS)
    @State private var quickLookController = ChatImageQuickLookController()
#endif

    private struct ReplyComposerContext: Identifiable {
        let id = UUID()
        let initialText: String
    }

    private var thread: BoardThread? {
        runtime.thread(boardPath: boardPath, uuid: threadUUID)
    }

    private func canEditPost(_ post: BoardPost) -> Bool {
        guard !post.isThreadBody else { return false }
        return runtime.hasPrivilege("wired.account.board.edit_all_threads_and_posts")
        || (runtime.hasPrivilege("wired.account.board.edit_own_threads_and_posts") && post.isOwn)
    }

    private func canDeletePost(_ post: BoardPost) -> Bool {
        guard !post.isThreadBody else { return false }
        return runtime.hasPrivilege("wired.account.board.delete_all_threads_and_posts")
        || (runtime.hasPrivilege("wired.account.board.delete_own_threads_and_posts") && post.isOwn)
    }

    private var canReplyToThread: Bool {
        runtime.board(path: boardPath)?.writable ?? false
    }

    private func makeQuotedReplyText(from post: BoardPost, selectedText: String?) -> String {
        let chosen = (selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        ? selectedText!.trimmingCharacters(in: .whitespacesAndNewlines)
        : post.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let date = PostRowView.dateString(post.postDate)
        let lines = chosen.components(separatedBy: .newlines)
        let quotedBlock = ([ "\(post.nick) (\(date))" ] + lines).map { "> \($0)" }.joined(separator: "\n")
        return quotedBlock + "\n\n"
    }

    private func openReplyFromPost(_ post: BoardPost, selectedText: String?) {
        guard canReplyToThread else { return }
        let prefill = makeQuotedReplyText(from: post, selectedText: selectedText)
        replyComposerContext = ReplyComposerContext(initialText: prefill)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2), action)
            } else {
                action()
            }
        }
    }

    @discardableResult
    private func scrollToPendingPostIfNeeded(_ proxy: ScrollViewProxy, animated: Bool = true) -> Bool {
        guard let target = runtime.pendingBoardPostScrollTarget, target.threadUUID == threadUUID else {
            return false
        }

        let action = {
            proxy.scrollTo(target.postUUID, anchor: .center)
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2), action)
            } else {
                action()
            }
            runtime.pendingBoardPostScrollTarget = nil
        }

        return true
    }

    private func sortedPosts(_ posts: [BoardPost]) -> [BoardPost] {
        posts.sorted { lhs, rhs in
            if lhs.isThreadBody != rhs.isThreadBody {
                return lhs.isThreadBody && !rhs.isThreadBody
            }
            if lhs.postDate != rhs.postDate {
                return lhs.postDate < rhs.postDate
            }
            return lhs.uuid < rhs.uuid
        }
    }

    var body: some View {
        Group {
            if let thread {
                postsContainer(for: thread)
            } else {
                ContentUnavailableView("Thread unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .sheet(item: $postToEdit) { post in
            EditPostView(post: post, thread: thread)
                .environment(runtime)
        }
        .sheet(item: $replyComposerContext) { context in
            if let thread {
                ReplyView(thread: thread, initialText: context.initialText)
                    .environment(runtime)
            }
        }
        .confirmationDialog(
            "Delete post?",
            isPresented: Binding(
                get: { postToDelete != nil },
                set: { if !$0 { postToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let post = postToDelete, let thread else { return }
                Task {
                    do {
                        try await runtime.deletePost(uuid: post.uuid)
                        try await runtime.getPosts(forThread: thread)
                        await MainActor.run { postToDelete = nil }
                    } catch {
                        await MainActor.run {
                            runtime.lastError = error
                            postToDelete = nil
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                postToDelete = nil
            }
        } message: {
            Text(postToDelete?.text ?? "")
        }
        .background(Color.boardsTextBackground)
        .onChange(of: threadUUID) {
            selectedImageSource = nil
        }
    }

    private func postsContainer(for thread: BoardThread) -> some View {
        GeometryReader { geometry in
            let postContentWidth = max(280, geometry.size.width - 32)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        postsContent(for: thread, availableContentWidth: postContentWidth)
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                }
                .background(Color.boardsTextBackground)
#if os(macOS)
                .chatQuickLookSpaceMonitor(isEnabled: selectedImageSource != nil) {
                    openSelectedImageQuickLook()
                }
#endif
                .onAppear {
                    if thread.postsLoaded {
                        if !scrollToPendingPostIfNeeded(proxy, animated: false) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                .onChange(of: thread.postsLoaded) { _, loaded in
                    guard loaded else { return }
                    if !scrollToPendingPostIfNeeded(proxy, animated: false) {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: thread.posts.count) { _, _ in
                    guard thread.postsLoaded else { return }
                    if !scrollToPendingPostIfNeeded(proxy) {
                        scrollToBottom(proxy, animated: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func postsContent(for thread: BoardThread, availableContentWidth: CGFloat) -> some View {
        if !thread.postsLoaded {
            ProgressView("Loading posts…")
                .padding(40)
        } else if thread.posts.isEmpty {
            ContentUnavailableView("No Posts", systemImage: "text.alignleft")
                .padding(40)
        } else {
            ForEach(sortedPosts(thread.posts)) { post in
                postRow(post, availableContentWidth: availableContentWidth)
            }
        }
    }

    private var canReact: Bool {
        runtime.hasPrivilege("wired.account.board.add_reactions")
    }

    private func postRow(_ post: BoardPost, availableContentWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            PostRowView(
                post: post,
                highlightQuery: highlightQuery,
                availableContentWidth: availableContentWidth,
                canReply: canReplyToThread,
                canEdit: canEditPost(post),
                canDelete: canDeletePost(post),
                canReact: canReact,
                selectedImageSource: selectedImageSource,
                onReply: { openReplyFromPost(post, selectedText: nil) },
                onQuote: { selectedText in openReplyFromPost(post, selectedText: selectedText) },
                onEdit: { postToEdit = post },
                onDelete: { postToDelete = post },
                onToggleReaction: { emoji in
                    Task { try? await runtime.toggleReaction(emoji: emoji, forPost: post) }
                },
                onSelectImage: { source in
                    selectedImageSource = source
                },
                onOpenQuickLook: { source in
                    selectedImageSource = source
                    openQuickLook(for: source)
                }
            )
            .padding(.horizontal)
            .id(post.uuid)
            .task(id: post.uuid) {
                guard !post.reactionsLoaded else { return }
                try? await runtime.getReactions(forPost: post)
            }

            Divider()
                .padding(.horizontal)
        }
    }

#if os(macOS)
    private func openSelectedImageQuickLook() {
        guard let selectedImageSource else { return }
        openQuickLook(for: selectedImageSource)
    }

    private func openQuickLook(for source: ChatImageQuickLookSource) {
        Task {
            do {
                let url = try await source.quickLookURL(connectionID: runtime.id, runtime: runtime)
                await MainActor.run {
                    quickLookController.present(localURL: url, title: source.title)
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
