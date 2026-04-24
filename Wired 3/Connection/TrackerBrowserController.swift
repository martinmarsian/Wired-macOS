//
//  TrackerBrowserController.swift
//  Wired 3
//
//  Created by Codex on 03/04/2026.
//

import Foundation
import Observation
import KeychainSwift
import WiredSwift

struct TrackerServerNode: Identifiable, Hashable {
    let id: String
    let name: String
    let serverDescription: String
    let urlString: String
    let categoryPath: String
    let users: UInt32
    let filesCount: UInt64
    let filesSize: UInt64
    let isTracker: Bool

    init(
        name: String,
        serverDescription: String,
        urlString: String,
        categoryPath: String,
        users: UInt32,
        filesCount: UInt64,
        filesSize: UInt64,
        isTracker: Bool
    ) {
        self.name = name
        self.serverDescription = serverDescription
        self.urlString = urlString
        self.categoryPath = categoryPath
        self.users = users
        self.filesCount = filesCount
        self.filesSize = filesSize
        self.isTracker = isTracker
        self.id = "\(categoryPath)|\(urlString)|\(name)"
    }
}

struct TrackerCategoryNode: Identifiable, Hashable {
    let path: String
    let name: String
    var categories: [TrackerCategoryNode]
    var servers: [TrackerServerNode]

    var id: String { path }
}

struct TrackerBrowseState: Equatable {
    var isLoading: Bool = false
    var categories: [TrackerCategoryNode] = []
    var rootServers: [TrackerServerNode] = []
    var lastError: String?
    var lastLoadedAt: Date?

    var hasContent: Bool {
        !categories.isEmpty || !rootServers.isEmpty
    }
}

@MainActor
@Observable
final class TrackerBrowserController {
    private var states: [UUID: TrackerBrowseState] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    func state(for bookmarkID: UUID) -> TrackerBrowseState {
        states[bookmarkID] ?? TrackerBrowseState()
    }

    func refreshIfNeeded(_ bookmark: TrackerBookmark) {
        let current = state(for: bookmark.id)
        guard !current.isLoading else { return }
        guard current.lastLoadedAt == nil else { return }
        refresh(bookmark)
    }

    func refresh(_ bookmark: TrackerBookmark) {
        let snapshot = bookmark.snapshot
        let password = KeychainProvider.password(for: snapshot.credentialKey)
        let existing = states[snapshot.id] ?? TrackerBrowseState()

        tasks[snapshot.id]?.cancel()
        states[snapshot.id] = TrackerBrowseState(
            isLoading: true,
            categories: existing.categories,
            rootServers: existing.rootServers,
            lastError: nil,
            lastLoadedAt: existing.lastLoadedAt
        )

        tasks[snapshot.id] = Task.detached(priority: .userInitiated) {
            let result = await Self.browse(snapshot: snapshot, password: password)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                switch result {
                case .success(let response):
                    let built = Self.buildTree(
                        categories: response.categories,
                        servers: response.servers
                    )

                    self.states[snapshot.id] = TrackerBrowseState(
                        isLoading: false,
                        categories: built.categories,
                        rootServers: built.rootServers,
                        lastError: nil,
                        lastLoadedAt: response.loadedAt
                    )

                case .failure(let error):
                    let current = self.states[snapshot.id] ?? TrackerBrowseState()
                    self.states[snapshot.id] = TrackerBrowseState(
                        isLoading: false,
                        categories: current.categories,
                        rootServers: current.rootServers,
                        lastError: Self.errorMessage(from: error),
                        lastLoadedAt: current.lastLoadedAt
                    )
                }
            }
        }
    }

    func clear(for bookmarkID: UUID) {
        tasks[bookmarkID]?.cancel()
        tasks[bookmarkID] = nil
        states[bookmarkID] = nil
    }

    private nonisolated static func browse(
        snapshot: TrackerBookmarkSnapshot,
        password: String
    ) async -> Result<(categories: [String], servers: [TrackerServerNode], loadedAt: Date), Error> {
        let connection = AsyncConnection(withSpec: spec)
        let url = snapshot.makeURL(password: password)

        do {
            try connection.connect(
                withUrl: url,
                cipher: .ECDH_CHACHA20_POLY1305,
                compression: .LZ4,
                checksum: .HMAC_256
            )
            defer { connection.disconnect() }

            let categoriesMessage = P7Message(withName: "wired.tracker.get_categories", spec: spec)
            let categoriesReply = try await connection.sendAsync(categoriesMessage)
            let categories = (categoriesReply?.name == "wired.tracker.categories")
                ? (categoriesReply?.stringList(forField: "wired.tracker.categories") ?? [])
                : []

            let serversMessage = P7Message(withName: "wired.tracker.get_servers", spec: spec)
            let stream = try connection.sendAndWaitMany(serversMessage)

            var servers: [TrackerServerNode] = []
            for try await reply in stream {
                guard reply.name == "wired.tracker.server_list" else { continue }
                servers.append(parseServer(from: reply))
            }

            return .success((categories, servers, Date()))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func parseServer(from message: P7Message) -> TrackerServerNode {
        TrackerServerNode(
            name: message.string(forField: "wired.info.name") ?? "Server",
            serverDescription: message.string(forField: "wired.info.description") ?? "",
            urlString: message.string(forField: "wired.tracker.url") ?? "",
            categoryPath: normalizeCategoryPath(message.string(forField: "wired.tracker.category") ?? ""),
            users: message.uint32(forField: "wired.tracker.users") ?? 0,
            filesCount: message.uint64(forField: "wired.info.files.count") ?? 0,
            filesSize: message.uint64(forField: "wired.info.files.size") ?? 0,
            isTracker: message.bool(forField: "wired.tracker.tracker") ?? false
        )
    }

    private nonisolated static func normalizeCategoryPath(_ value: String) -> String {
        value
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    private nonisolated static func buildTree(
        categories rawCategories: [String],
        servers: [TrackerServerNode]
    ) -> (categories: [TrackerCategoryNode], rootServers: [TrackerServerNode]) {
        final class MutableCategory {
            let name: String
            let path: String
            var categories: [String: MutableCategory] = [:]
            var servers: [TrackerServerNode] = []

            init(name: String, path: String) {
                self.name = name
                self.path = path
            }
        }

        let root = MutableCategory(name: "", path: "")

        for rawPath in rawCategories {
            let normalized = normalizeCategoryPath(rawPath)
            guard !normalized.isEmpty else { continue }

            let components = normalized.split(separator: "/").map(String.init)
            var current = root
            var currentPath = ""

            for component in components {
                currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
                if let existing = current.categories[component] {
                    current = existing
                } else {
                    let created = MutableCategory(name: component, path: currentPath)
                    current.categories[component] = created
                    current = created
                }
            }
        }

        let knownPaths = Set(rawCategories.map(normalizeCategoryPath))

        for server in servers {
            let normalizedPath = normalizeCategoryPath(server.categoryPath)
            guard !normalizedPath.isEmpty, knownPaths.contains(normalizedPath) else {
                root.servers.append(server)
                continue
            }

            let components = normalizedPath.split(separator: "/").map(String.init)
            var current = root
            var resolved = true

            for component in components {
                guard let next = current.categories[component] else {
                    resolved = false
                    break
                }
                current = next
            }

            if resolved {
                current.servers.append(server)
            } else {
                root.servers.append(server)
            }
        }

        func freeze(_ node: MutableCategory) -> TrackerCategoryNode {
            let nestedCategories = node.categories.values
                .map(freeze)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let nestedServers = node.servers
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            return TrackerCategoryNode(
                path: node.path,
                name: node.name,
                categories: nestedCategories,
                servers: nestedServers
            )
        }

        let categories = root.categories.values
            .map(freeze)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rootServers = root.servers
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return (categories, rootServers)
    }

    private nonisolated static func errorMessage(from error: Error) -> String {
        if let asyncError = error as? AsyncConnectionError {
            switch asyncError {
            case .notConnected:
                return "Tracker connection is not active."
            case .writeFailed:
                return "Failed to send tracker request."
            case .serverError(let message):
                return message.string(forField: "wired.error.string")
                    ?? message.string(forField: "wired.error")
                    ?? "Tracker request failed."
            }
        }

        return (error as NSError).localizedDescription
    }
}

enum KeychainProvider {
    static func password(for key: String) -> String {
        KeychainSwift().get(key) ?? ""
    }
}
