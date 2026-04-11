//
//  Wired_3Tests.swift
//  Wired 3Tests
//
//  Created by Rafaël Warnault on 18/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import Foundation
import SwiftData
import SwiftUI
import Testing
import WiredSwift
@testable import Wired_Client

struct Wired_3Tests {
    @Test
    func stringIsShortEmojiOnlyRecognizesOneToThreeEmoji() {
        #expect("🙂".isShortEmojiOnly)
        #expect("🙂🙂🙂".isShortEmojiOnly)
        #expect(" 🙂🙂 ".isShortEmojiOnly)
        #expect(!"".isShortEmojiOnly)
        #expect(!"🙂🙂🙂🙂".isShortEmojiOnly)
        #expect(!"🙂 hi".isShortEmojiOnly)
        #expect(!"123".isShortEmojiOnly)
    }

    @Test
    func stringReplacingEmoticonsAppliesProvidedMap() {
        let result = "Hello :) :( <3".replacingEmoticons(using: [
            ":)": "🙂",
            ":(": "🙁",
            "<3": "❤️"
        ])

        #expect(result == "Hello 🙂 🙁 ❤️")
    }

    @Test
    func stringDetectedURLsDeduplicatesPlainAndMarkdownLinks() {
        let text = """
        Visit https://example.com/image.png and [docs](https://example.com/docs).
        Duplicate markdown [again](https://example.com/docs) and plain https://example.com/image.png
        """

        let urls = text.detectedURLs().map(\.absoluteString)

        #expect(urls == [
            "https://example.com/image.png",
            "https://example.com/docs"
        ])
    }

    @Test
    func stringDetectedHTTPImageURLsKeepsOnlySupportedHttpImages() {
        let text = """
        https://example.com/a.png
        https://example.com/b.jpeg
        https://example.com/c.txt
        ftp://example.com/d.png
        """

        let urls = text.detectedHTTPImageURLs().map(\.absoluteString)

        #expect(urls == [
            "https://example.com/a.png",
            "https://example.com/b.jpeg"
        ])
    }

    @Test
    func attributedWithDetectedLinksMarksLinkRanges() {
        let attributed = "Read https://example.com/docs".attributedWithDetectedLinks()
        let linkedRuns = attributed.runs.compactMap { run -> URL? in
            run.link
        }

        #expect(linkedRuns.map(\.absoluteString) == ["https://example.com/docs"])
    }

    @Test
    func attributedWithMarkdownAndDetectedLinksHighlightsQueryAndPreservesLinks() {
        let attributed = "See [guide](https://example.com/guide) and café notes"
            .attributedWithMarkdownAndDetectedLinks(highlightQuery: "cafe guide")

        let linkedRuns = attributed.runs.compactMap { run -> URL? in
            run.link
        }
        let highlightedText = attributed.runs.compactMap { run -> String? in
            guard run.backgroundColor != nil else { return nil }
            return String(attributed[run.range].characters)
        }

        #expect(linkedRuns.map(\.absoluteString) == ["https://example.com/guide"])
        #expect(highlightedText.contains("guide"))
        #expect(highlightedText.contains("café"))
    }

    @Test
    func timeIntervalStringFromTimeIntervalFormatsPositiveAndNegativeValues() {
        #expect(TimeInterval(45).stringFromTimeInterval() == "00:45 seconds")
        #expect(TimeInterval(125).stringFromTimeInterval() == "02:05 minutes")
        #expect(TimeInterval(-45).stringFromTimeInterval() == "00:45 seconds ago")
    }

    @Test
    func remoteQuickLookSupportKeepsOnlyPreviewableSelectedFiles() {
        let selected = RemoteQuickLookSupport.selectedPreviewableItems(
            from: [
                FileItem("Folder", path: "/Folder", type: .directory),
                FileItem("Small.txt", path: "/Small.txt", type: .file),
                oversizedPreviewItem(path: "/Huge.mov"),
                FileItem("Image.jpg", path: "/Image.jpg", type: .file)
            ],
            selectedPaths: ["/Folder", "/Small.txt", "/Huge.mov", "/Image.jpg"]
        )

        #expect(selected.map(\.path) == ["/Small.txt", "/Image.jpg"])
    }

    @Test
    func remoteQuickLookSupportBuildsStableCacheURLsThatPreserveExtensions() throws {
        let baseDirectory = try TestData.makeTemporaryDirectory(prefix: "ql-cache")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let item = FileItem("Picture.final.png", path: "/Media/Picture.final.png", type: .file)
        let url = RemoteQuickLookSupport.previewURL(
            baseDirectory: baseDirectory,
            connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            item: item
        )

        #expect(url.deletingLastPathComponent().lastPathComponent == "RemoteQuickLook")
        #expect(url.lastPathComponent.hasPrefix("Picture.final-"))
        #expect(url.pathExtension == "png")
    }

    @Test
    func remoteQuickLookSupportInitialSelectionPrefersMatchingPathAndFallsBackToZero() {
        let items = [
            FileItem("One.txt", path: "/One.txt", type: .file),
            FileItem("Two.txt", path: "/Two.txt", type: .file)
        ]

        #expect(RemoteQuickLookSupport.initialSelectionIndex(items: items, preferredPath: "/Two.txt") == 1)
        #expect(RemoteQuickLookSupport.initialSelectionIndex(items: items, preferredPath: "/Missing.txt") == 0)
        #expect(RemoteQuickLookSupport.initialSelectionIndex(items: items, preferredPath: nil) == 0)
    }

    @Test
    func remoteQuickLookSupportRequestsConfirmationOnlyForLargeUncachedFiles() {
        let regular = FileItem("Small.txt", path: "/Small.txt", type: .file)
        let oversized = oversizedPreviewItem(path: "/Huge.mov")

        #expect(!RemoteQuickLookSupport.shouldConfirmDownload(for: regular, hasCachedPreview: false))
        #expect(RemoteQuickLookSupport.shouldConfirmDownload(for: oversized, hasCachedPreview: false))
        #expect(!RemoteQuickLookSupport.shouldConfirmDownload(for: oversized, hasCachedPreview: true))
    }

    @Test
    func serverTrustStoreCreatesStorageKeysAndPersistsFingerprints() {
        let host = "trust.example.org"
        let port = 4871
        let key = ServerTrustStore.storageKey(host: host, port: port)
        let defaults = UserDefaults(suiteName: "fr.read-write.Wired3.TrustStore")

        defaults?.removeObject(forKey: key)
        defer { defaults?.removeObject(forKey: key) }

        #expect(ServerTrustStore.storedFingerprint(host: host, port: port) == nil)

        ServerTrustStore.storeFingerprint("abc123", host: host, port: port)

        #expect(ServerTrustStore.storedFingerprint(host: host, port: port) == "abc123")

        ServerTrustStore.removeFingerprint(host: host, port: port)

        #expect(ServerTrustStore.storedFingerprint(host: host, port: port) == nil)
    }

    @Test
    func serverTrustStoreEvaluateHandlesNewKnownAndChangedFingerprints() {
        let host = "identity.example.org"
        let port = 2000
        let key = ServerTrustStore.storageKey(host: host, port: port)
        let defaults = UserDefaults(suiteName: "fr.read-write.Wired3.TrustStore")

        defaults?.removeObject(forKey: key)
        defer { defaults?.removeObject(forKey: key) }

        let firstDecision = ServerTrustStore.evaluate(
            fingerprint: "aaaa",
            host: host,
            port: port,
            strictIdentity: false
        )
        let secondDecision = ServerTrustStore.evaluate(
            fingerprint: "aaaa",
            host: host,
            port: port,
            strictIdentity: true
        )
        let changedDecision = ServerTrustStore.evaluate(
            fingerprint: "bbbb",
            host: host,
            port: port,
            strictIdentity: true
        )

        switch firstDecision {
        case .newKey(let fingerprint):
            #expect(fingerprint == "aaaa")
        default:
            Issue.record("Expected a new key decision on first use")
        }

        switch secondDecision {
        case .allow:
            break
        default:
            Issue.record("Expected allow for the stored fingerprint")
        }

        switch changedDecision {
        case .changed(let stored, let received, let strict):
            #expect(stored == "aaaa")
            #expect(received == "bbbb")
            #expect(strict)
        default:
            Issue.record("Expected changed decision for a mismatched fingerprint")
        }
    }

    @MainActor
    @Test
    func chatMatchesFiltersAndPreviewsMessagesAndTopic() {
        let chat = TestData.makeChat(name: "General")
        let alice = TestData.makeUser(id: 1, nick: "Alice")
        let bob = TestData.makeUser(id: 2, nick: "Bob")
        chat.topic = Topic(topic: "Café planning", nick: "Alice", time: TestData.referenceDate)
        chat.messages = [
            ChatEvent(chat: chat, user: alice, type: .say, text: "Welcome everyone", date: TestData.referenceDate),
            ChatEvent(chat: chat, user: bob, type: .say, text: "Budget for the cafe meetup", date: TestData.referenceDate)
        ]

        #expect(chat.matchesSearch("General"))
        #expect(chat.matchesSearch("cafe"))
        #expect(chat.matchesSearch("Bob"))
        #expect(!chat.matchesSearch("nonexistent"))

        let filtered = chat.filteredMessages(matching: "cafe")
        #expect(filtered.count == 1)
        #expect(filtered.first?.text == "Budget for the cafe meetup")
        #expect(chat.previewText(matching: "cafe") == "Budget for the cafe meetup")
        #expect(chat.previewText(matching: "planning") == "Café planning")
    }

    @MainActor
    @Test
    func chatTypingHelpersTrackActiveUsersAndIndicatorText() {
        let chat = TestData.makeChat(name: "Support")
        let alice = TestData.makeUser(id: 1, nick: "Alice")
        let bob = TestData.makeUser(id: 2, nick: "Bob")
        let carol = TestData.makeUser(id: 3, nick: "Carol")
        let now = Date()
        chat.users = [alice, bob, carol]

        chat.setTyping(userID: alice.id, expiresAt: now.addingTimeInterval(60))
        chat.setTyping(userID: bob.id, expiresAt: now.addingTimeInterval(30))
        chat.setTyping(userID: carol.id, expiresAt: now.addingTimeInterval(-5))
        chat.removeExpiredTypingUsers(referenceDate: now)

        #expect(chat.activeTypingUserIDs == [1, 2])
        #expect(chat.primaryTypingUser?.nick == "Alice")
        #expect(chat.typingIndicatorText == "Alice and Bob are typing...")

        chat.clearTyping(userID: bob.id)
        #expect(chat.typingIndicatorText == "Alice is typing...")

        chat.clearAllTyping()
        #expect(chat.typingIndicatorText == nil)
    }

    @MainActor
    @Test
    func chatEventMatchesSearchAndProvidesFallbackPreview() {
        let chat = TestData.makeChat(name: "Images")
        let user = TestData.makeUser(id: 1, nick: "Alice")
        let message = ChatEvent(chat: chat, user: user, type: .say, text: "Look at this https://example.com/photo.jpg")
        let emptyText = ChatEvent(chat: chat, user: user, type: .say, text: "   ")

        #expect(message.matchesSearch("alice"))
        #expect(message.matchesSearch("photo"))
        #expect(!message.matchesSearch("missing"))
        #expect(message.searchPreviewText == "Look at this https://example.com/photo.jpg")
        #expect(emptyText.searchPreviewText == "Alice")
        #expect(message.cachedPrimaryHTTPImageURL?.absoluteString == "https://example.com/photo.jpg")
    }

    @Test
    func userTransferSnapshotsReportProgressQueueAndEta() {
        let queuedTransfer = UserActiveTransfer(
            type: .download,
            path: "/Uploads/file.zip",
            dataSize: 100,
            rsrcSize: 20,
            transferred: 0,
            speed: 0,
            queuePosition: 3
        )
        let runningTransfer = UserActiveTransfer(
            type: .upload,
            path: "/Uploads/video.mov",
            dataSize: 1_000,
            rsrcSize: 0,
            transferred: 500,
            speed: 100,
            queuePosition: 0
        )

        #expect(queuedTransfer.totalSize == 120)
        #expect(queuedTransfer.isQueued)
        #expect(queuedTransfer.stateDescription == "Queued at position 3")
        #expect(queuedTransfer.displaySnapshot.statusText == "Queued at position 3")

        let snapshot = runningTransfer.displaySnapshot
        #expect(snapshot.typeTitle == "Upload")
        #expect(snapshot.progressFraction == 0.5)
        #expect(snapshot.speedText != nil)
        #expect(snapshot.statusText.contains("/s"))
        #expect(snapshot.statusText.contains("00:05"))
    }

    @Test
    func monitoredUserReflectsActiveTransferDirectionAndSpeed() {
        let transfer = UserActiveTransfer(
            type: .download,
            path: "/Uploads/file.zip",
            dataSize: 200,
            rsrcSize: 0,
            transferred: 50,
            speed: 42,
            queuePosition: 0
        )
        let monitored = MonitoredUser(
            id: 1,
            nick: "Alice",
            status: nil,
            icon: Data(),
            idle: false,
            color: 0,
            idleTime: nil,
            activeTransfer: transfer
        )

        #expect(monitored.isDownloading)
        #expect(!monitored.isUploading)
        #expect(monitored.transferSpeed == 42)
    }

    @Test
    func wiredEventsStoreDefaultConfigurationsFollowMenuOrderAndSpecialDefaults() {
        let configurations = WiredEventsStore.defaultConfigurations()

        #expect(configurations.map(\.tag) == WiredEventTag.menuOrder)
        #expect(configurations.first(where: { $0.tag == .userJoined })?.postInChat == true)
        #expect(configurations.first(where: { $0.tag == .userChangedNick })?.postInChat == true)
        #expect(configurations.first(where: { $0.tag == .userLeft })?.postInChat == true)
        #expect(configurations.first(where: { $0.tag == .userChangedStatus })?.postInChat == false)
        #expect(configurations.first(where: { $0.tag == .chatReceived })?.postInChat == false)
    }

    @Test
    func wiredEventsStoreLoadConfigurationsMergesSavedValuesWithDefaults() {
        let testDefaults = TestData.makeDefaults()
        let defaults = testDefaults.defaults
        defer { defaults.removePersistentDomain(forName: testDefaults.suiteName) }

        WiredEventsStore.saveConfigurations([
            WiredEventConfiguration(
                tag: .chatReceived,
                playSound: true,
                sound: "Ping",
                bounceInDock: true,
                postInChat: true,
                showAlert: true,
                notificationCenter: true
            )
        ], defaults: defaults)

        let configurations = WiredEventsStore.loadConfigurations(defaults: defaults)

        #expect(configurations.map(\.tag) == WiredEventTag.menuOrder)
        #expect(configurations.first(where: { $0.tag == .chatReceived })?.playSound == true)
        #expect(configurations.first(where: { $0.tag == .chatReceived })?.sound == "Ping")
        #expect(configurations.first(where: { $0.tag == .chatReceived })?.postInChat == true)
        #expect(configurations.first(where: { $0.tag == .userJoined })?.postInChat == true)
        #expect(configurations.first(where: { $0.tag == .transferFinished })?.playSound == false)
    }

    @Test
    func wiredEventsStoreSaveConfigurationUpdatesSingleTagAndVolumeClamps() {
        let testDefaults = TestData.makeDefaults()
        let defaults = testDefaults.defaults
        defer { defaults.removePersistentDomain(forName: testDefaults.suiteName) }

        WiredEventsStore.saveConfiguration(
            WiredEventConfiguration(tag: .messageReceived, playSound: true, sound: "Funk"),
            defaults: defaults
        )

        let saved = WiredEventsStore.configuration(for: .messageReceived, defaults: defaults)
        #expect(saved.playSound)
        #expect(saved.sound == "Funk")

        WiredEventsStore.saveVolume(1.5, defaults: defaults)
        #expect(WiredEventsStore.loadVolume(defaults: defaults) == 1.0)

        WiredEventsStore.saveVolume(-0.25, defaults: defaults)
        #expect(WiredEventsStore.loadVolume(defaults: defaults) == 0.0)
    }

    @MainActor
    @Test
    func filesViewModelNormalizesPathsAndDetectsAncestors() {
        let viewModel = FilesViewModel.empty()

        #expect(viewModel.normalizedRemotePath("/") == "/")
        #expect(viewModel.normalizedRemotePath("///Uploads///Music///") == "/Uploads///Music")
        #expect(viewModel.parentPath(of: "/Uploads/Music/song.mp3") == "/Uploads/Music")
        #expect(viewModel.parentPath(of: "/") == nil)
        #expect(viewModel.isSameOrDescendant("/Uploads/Music/song.mp3", of: "/Uploads"))
        #expect(!viewModel.isSameOrDescendant("/Archive/song.mp3", of: "/Uploads"))
    }

    @MainActor
    @Test
    func filesViewModelVisibleTreeNodesSortsDirectoriesFirstAndTraversesExpandedBranches() {
        let viewModel = FilesViewModel.empty()
        let uploads = FileItem("Uploads", path: "/Uploads", type: .uploads)
        let docs = FileItem("Docs", path: "/Docs", type: .directory)
        let readme = FileItem("README.txt", path: "/README.txt", type: .file)
        let nested = FileItem("Song.mp3", path: "/Uploads/Song.mp3", type: .file)

        viewModel.treeRootPath = "/"
        viewModel.treeChildrenByPath = [
            "/": [readme, uploads, docs],
            "/Uploads": [nested]
        ]
        viewModel.expandedTreePaths = ["/", "/Uploads"]

        let nodes = viewModel.visibleTreeNodes()

        #expect(nodes.map(\.path) == [
            "/Docs",
            "/Uploads",
            "/Uploads/Song.mp3",
            "/README.txt"
        ])
        #expect(nodes.map(\.level) == [0, 0, 1, 0])
    }

    @MainActor
    @Test
    func filesViewModelSelectedTreeItemAndSyncTreeDetectionUseLocalState() {
        let viewModel = FilesViewModel.empty()
        let syncFolder = FileItem("Sync", path: "/Sync", type: .sync)
        let childFile = FileItem("Notes.txt", path: "/Sync/Notes.txt", type: .file)

        viewModel.treeRootPath = "/"
        viewModel.treeChildrenByPath = [
            "/": [syncFolder],
            "/Sync": [childFile]
        ]
        viewModel.treeSelectionPath = "/Sync/Notes.txt"

        #expect(viewModel.selectedTreeItem()?.path == "/Sync/Notes.txt")
        #expect(viewModel.isInsideSyncTree("/Sync/Notes.txt"))
        #expect(!viewModel.isInsideSyncTree("/Public/Notes.txt"))
    }

    @MainActor
    @Test
    func filesViewModelSearchAndClearSearchSwapBetweenSearchResultsAndSavedBrowseState() async {
        let viewModel = FilesViewModel.empty()
        let runtime = TestData.makeRuntime()
        let service = TestFileService()
        let searchResult = FileItem("Guide.txt", path: "/Docs/Guide.txt", type: .file)

        service.searchResults = [searchResult]
        viewModel.columns = [FileColumn(path: "/", items: [FileItem("Docs", path: "/Docs", type: .directory)])]
        viewModel.treeChildrenByPath = ["/": [FileItem("Docs", path: "/Docs", type: .directory)]]
        viewModel.treeRootPath = "/"
        viewModel.treeSelectionPath = "/Docs"
        viewModel.expandedTreePaths = ["/", "/Docs"]
        viewModel.configure(fileService: service, runtime: runtime)

        await viewModel.search(query: "guide")

        #expect(viewModel.isSearchMode)
        #expect(!viewModel.isSearching)
        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns.first?.items.map(\.path) == ["/Docs/Guide.txt"])
        #expect(viewModel.treeChildrenByPath["/"]?.map(\.path) == ["/Docs/Guide.txt"])
        #expect(viewModel.treeSelectionPath == nil)

        await viewModel.clearSearch()

        #expect(!viewModel.isSearchMode)
        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns.first?.items.map(\.path) == ["/Docs"])
        #expect(viewModel.treeChildrenByPath["/"]?.map(\.path) == ["/Docs"])
        #expect(viewModel.treeSelectionPath == "/Docs")
        #expect(viewModel.expandedTreePaths == ["/", "/Docs"])
    }

    @MainActor
    @Test
    func filesViewModelHandleSelectionUpdatesLocalSelectionForFiles() async {
        let viewModel = FilesViewModel.empty()
        let file = FileItem("Readme.txt", path: "/Readme.txt", type: .file)
        let fileID = file.id
        var appendedColumns: [FileColumn] = []

        viewModel.columns = [FileColumn(path: "/", items: [file])]

        viewModel.handleSelection(fileID, in: 0) { column in
            appendedColumns.append(column)
        }

        try? await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns[0].selection == fileID)
        #expect(viewModel.treeSelectionPath == "/Readme.txt")
        #expect(appendedColumns.isEmpty)
    }

    @MainActor
    @Test
    func filesViewModelRemoteDirectoryDeletedTrimsColumnsAndSelection() async {
        let viewModel = FilesViewModel.empty()
        let folder = FileItem("Docs", path: "/Docs", type: .directory)
        let child = FileItem("Guide.txt", path: "/Docs/Guide.txt", type: .file)

        viewModel.columns = [
            FileColumn(path: "/", items: [folder], selection: folder.id),
            FileColumn(path: "/Docs", items: [child], selection: child.id)
        ]
        viewModel.treeRootPath = "/"
        viewModel.treeChildrenByPath = [
            "/": [folder],
            "/Docs": [child]
        ]
        viewModel.treeSelectionPath = "/Docs/Guide.txt"
        viewModel.expandedTreePaths = ["/", "/Docs"]

        await viewModel.remoteDirectoryDeleted("/Docs")

        #expect(viewModel.columns.count == 1)
        #expect(viewModel.treeSelectionPath == "/")
        #expect(viewModel.treeChildrenByPath["/Docs"] == nil)
        #expect(!viewModel.expandedTreePaths.contains("/Docs"))
    }

    @MainActor
    @Test
    func filesViewModelReloadTreeDirectoryHandlesFileNotFoundAndPermissionDenied() async {
        let runtime = TestData.makeRuntime()
        let service = TestFileService()
        let viewModel = FilesViewModel.empty()

        viewModel.configure(fileService: service, runtime: runtime)
        viewModel.treeRootPath = "/"
        viewModel.treeChildrenByPath = [
            "/Docs": [FileItem("Guide.txt", path: "/Docs/Guide.txt", type: .file)],
            "/Secret": [FileItem("note.txt", path: "/Secret/note.txt", type: .file)]
        ]
        viewModel.expandedTreePaths = ["/", "/Docs", "/Secret"]
        viewModel.treeSelectionPath = "/Docs/Guide.txt"

        service.listErrors["/Docs"] = WiredError(withTitle: "Missing", message: "file_not_found")
        service.listErrors["/Secret"] = WiredError(withTitle: "Denied", message: "permission_denied")

        await viewModel.reloadTreeDirectory("/Docs")
        await viewModel.reloadTreeDirectory("/Secret")

        #expect(viewModel.treeChildrenByPath["/Docs"] == nil)
        #expect(!viewModel.expandedTreePaths.contains("/Docs"))
        #expect(viewModel.treeSelectionPath == "/")
        #expect(viewModel.treeChildrenByPath["/Secret"]?.isEmpty == true)
        #expect(viewModel.error == nil)
    }

    @MainActor
    @Test
    func filesViewModelSyncDirectorySubscriptionsTracksDesiredPathsAndIgnoresBenignErrors() async {
        let runtime = TestData.makeRuntime()
        let service = TestFileService()
        let viewModel = FilesViewModel.empty()
        let docs = FileItem("Docs", path: "/Docs", type: .directory)

        viewModel.configure(fileService: service, runtime: runtime)
        viewModel.columns = [FileColumn(path: "/", items: [docs])]
        viewModel.treeChildrenByPath = ["/Docs": []]

        await viewModel.syncDirectorySubscriptions()

        #expect(service.subscribedPaths == ["/", "/Docs"])

        viewModel.treeChildrenByPath = [:]
        service.unsubscribeErrors["/Docs"] = WiredError(withTitle: "Missing", message: "file_not_found")

        await viewModel.syncDirectorySubscriptions()
        await viewModel.clearDirectorySubscriptions()

        #expect(service.unsubscribedPaths.contains("/Docs"))
        #expect(service.unsubscribedPaths.contains("/"))
        #expect(viewModel.error == nil)
    }

    @MainActor
    @Test
    func transferManagerClearPrepareAndActiveStateRespectTransferLifecycle() throws {
        let environment = try TestData.makeTransferManagerEnvironment()
        let running = Transfer(name: "download.bin", type: .download)
        running.state = .running
        running.speed = 200
        running.queuePosition = 3

        let finished = Transfer(name: "done.bin", type: .download)
        finished.state = .finished

        environment.context.insert(running)
        environment.context.insert(finished)
        try environment.context.save()
        environment.manager.attach(modelContext: environment.context)

        if let runningTransfer = environment.manager.transfers.first(where: { $0.name == "download.bin" }) {
            runningTransfer.state = .running
            runningTransfer.speed = 200
            runningTransfer.queuePosition = 3
        }

        #expect(environment.manager.hasActiveTransfers())

        environment.manager.prepareForTermination()

        let normalizedRunning = environment.manager.transfers.first(where: { $0.name == "download.bin" })
        #expect(normalizedRunning?.state == .paused)
        #expect(normalizedRunning?.speed == 0)
        #expect(normalizedRunning?.queuePosition == 0)
        #expect(!environment.manager.hasActiveTransfers())

        environment.manager.clear()

        #expect(environment.manager.transfers.map(\.name) == ["download.bin"])
    }

    @MainActor
    @Test
    func transferManagerQueueDownloadHandlesOverwriteMissingRuntimeAndExistingTransfers() throws {
        let tempDir = try TestData.makeTemporaryDirectory(prefix: "TransferQueue")
        let environment = try TestData.makeTransferManagerEnvironment()
        let connectionID = UUID()
        let file = FileItem("archive.zip", path: "/Uploads/archive.zip", type: .file)
        let destination = tempDir.appendingPathComponent("archive.zip").path

        FileManager.default.createFile(atPath: destination, contents: Data())
        switch environment.manager.queueDownload(file, to: destination, with: connectionID, overwriteExistingFile: false) {
        case .needsOverwrite(let path):
            #expect(path == destination)
        default:
            Issue.record("Expected overwrite prompt when destination file already exists")
        }

        try? FileManager.default.removeItem(atPath: destination)

        switch environment.manager.queueDownload(file, to: destination, with: connectionID, overwriteExistingFile: true) {
        case .failed:
            break
        default:
            Issue.record("Expected failure when no runtime is available to create the transfer")
        }

        let activeManager = try TestData.makeTransferManagerEnvironment()
        let activeTransfer = Transfer(name: file.name, type: .download)
        activeTransfer.connectionID = connectionID
        activeTransfer.remotePath = file.path
        activeTransfer.localPath = destination
        activeTransfer.state = .locallyQueued
        activeManager.context.insert(activeTransfer)
        try activeManager.context.save()
        activeManager.manager.attach(modelContext: activeManager.context)
        if let loaded = activeManager.manager.transfers.first {
            loaded.connectionID = connectionID
            loaded.remotePath = file.path
            loaded.localPath = destination
            loaded.state = .locallyQueued
            switch activeManager.manager.queueDownload(file, to: destination, with: connectionID, overwriteExistingFile: true) {
            case .resumed(let transfer):
                #expect(transfer.id == loaded.id)
            default:
                Issue.record("Expected active transfer to be reused")
            }
        } else {
            Issue.record("Expected persisted transfer to be restored")
        }
    }

    @MainActor
    @Test
    func transferManagerQueueDownloadResetsOrPreservesProgressDependingOnPartialPresence() throws {
        let tempDir = try TestData.makeTemporaryDirectory(prefix: "TransferResume")
        let file = FileItem("movie.mkv", path: "/Uploads/movie.mkv", type: .file)
        let connectionID = UUID()
        let destination = tempDir.appendingPathComponent("movie.mkv").path
        let partialPath = destination.appendingFormat(".%@", Wired.transfersFileExtension)

        do {
            let environment = try TestData.makeTransferManagerEnvironment()
            let transfer = Transfer(name: file.name, type: .download)
            transfer.connectionID = connectionID
            transfer.remotePath = file.path
            transfer.localPath = destination
            transfer.state = .paused
            transfer.dataTransferred = 50
            transfer.speed = 12
            transfer.error = "Old error"
            environment.context.insert(transfer)
            try environment.context.save()
            environment.manager.attach(modelContext: environment.context)

            guard let loaded = environment.manager.transfers.first else {
                Issue.record("Expected paused transfer to be restored")
                return
            }

            switch environment.manager.queueDownload(file, to: destination, with: connectionID, overwriteExistingFile: true) {
            case .resumed(let resumed):
                #expect(resumed.id == loaded.id)
                #expect(resumed.state == .locallyQueued)
                #expect(resumed.dataTransferred == 0)
                #expect(resumed.speed == 0)
                #expect(resumed.error.isEmpty)
            default:
                Issue.record("Expected paused transfer without partial file to restart from scratch")
            }
        }

        do {
            let environment = try TestData.makeTransferManagerEnvironment()
            let transfer = Transfer(name: file.name, type: .download)
            transfer.connectionID = connectionID
            transfer.remotePath = file.path
            transfer.localPath = destination
            transfer.state = .paused
            transfer.dataTransferred = 75
            transfer.speed = 18
            environment.context.insert(transfer)
            try environment.context.save()
            environment.manager.attach(modelContext: environment.context)
            FileManager.default.createFile(atPath: partialPath, contents: Data())
            defer { try? FileManager.default.removeItem(atPath: partialPath) }

            guard let loaded = environment.manager.transfers.first else {
                Issue.record("Expected paused transfer to be restored")
                return
            }

            switch environment.manager.queueDownload(file, to: destination, with: connectionID, overwriteExistingFile: true) {
            case .resumed(let resumed):
                #expect(resumed.id == loaded.id)
                #expect(resumed.state == .locallyQueued)
                #expect(resumed.dataTransferred == 75)
                #expect(resumed.speed == 18)
            default:
                Issue.record("Expected partial file to resume existing transfer without resetting progress")
            }
        }
    }

    @MainActor
    @Test
    func transferManagerStartPauseStopRemoveAndHooksManageLocalLifecycle() throws {
        let environment = try TestData.makeTransferManagerEnvironment()

        let queued = Transfer(name: "queued.bin", type: .download)
        queued.uri = "alice@example.org:4871"
        queued.state = .locallyQueued

        let paused = Transfer(name: "paused.bin", type: .download)
        paused.uri = "alice@example.org:4871"
        paused.state = .paused

        let noURI = Transfer(name: "local.bin", type: .upload)
        noURI.state = .finished

        environment.context.insert(queued)
        environment.context.insert(paused)
        environment.context.insert(noURI)
        try environment.context.save()
        environment.manager.attach(modelContext: environment.context)

        guard let queuedTransfer = environment.manager.transfers.first(where: { $0.name == "queued.bin" }),
              let pausedTransfer = environment.manager.transfers.first(where: { $0.name == "paused.bin" }),
              let noURITransfer = environment.manager.transfers.first(where: { $0.name == "local.bin" }) else {
            Issue.record("Expected transfers to be restored")
            return
        }

        environment.manager.pause(queuedTransfer)
        #expect(queuedTransfer.state == .pausing)

        environment.manager.stop(queuedTransfer)
        #expect(queuedTransfer.state == .stopping)

        environment.manager.start(pausedTransfer)
        #expect(pausedTransfer.state == .locallyQueued)
        #expect(pausedTransfer.error.isEmpty)

        environment.manager.remove(noURITransfer)

        #expect(environment.manager.transfers.contains(where: { $0.id == noURITransfer.id }) == false)
    }

    @MainActor
    @Test
    func connectionControllerHandleIncomingURLParsesRemotePathsAndPrefillsNewConnections() {
        let controller = ConnectionController(socketClient: SocketClient())
        let connectedRuntime = TestData.makeRuntime()
        connectedRuntime.status = .connected
        controller.runtimeStores = [connectedRuntime]

        let internalURL = URL(string: "wired:///Boards/News")!
        let internalAction = controller.handleIncomingURL(internalURL)
        #expect(internalAction?.connectionID == connectedRuntime.id)
        #expect(internalAction?.remotePath == "/Boards/News")
        #expect(controller.activeConnectionID == connectedRuntime.id)
        #expect(controller.requestedSelectionID == connectedRuntime.id)

        let missingLoginURL = URL(string: "wired://example.org:4871")!
        let missingLoginAction = controller.handleIncomingURL(missingLoginURL)
        #expect(missingLoginAction == nil)
        #expect(controller.presentedNewConnection?.hostname == "example.org:4871")

        let invalidSchemeURL = URL(string: "https://example.org/files")!
        #expect(controller.handleIncomingURL(invalidSchemeURL) == nil)
    }

    @MainActor
    @Test
    func connectionControllerSecurityOptionsUsesBookmarkFallbacksWhenNoLiveConfigurationExists() throws {
        let controller = ConnectionController(socketClient: SocketClient())
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Bookmark.self, configurations: configuration)
        let context = ModelContext(container)
        let bookmarkID = UUID()
        let bookmark = Bookmark(id: bookmarkID, name: "Example", hostname: "example.org:4871", login: "alice")
        bookmark.cipher = .ECDH_AES256_SHA256
        bookmark.compression = .DEFLATE
        bookmark.checksum = .HMAC_384
        context.insert(bookmark)
        try context.save()
        controller.attach(modelContext: context)

        let options = controller.securityOptions(for: bookmarkID)
        let fallback = controller.securityOptions(for: UUID())

        #expect(options == nil)
        #expect(fallback == nil)
    }

    @MainActor
    @Test
    func connectionControllerBookmarkQueriesUseAttachedModelContext() throws {
        let controller = ConnectionController(socketClient: SocketClient())
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Bookmark.self, configurations: configuration)
        let context = ModelContext(container)
        let zeta = Bookmark(id: UUID(), name: "Zeta", hostname: "zeta.example.org:4871", login: "z")
        let alpha = Bookmark(id: UUID(), name: "Alpha", hostname: "alpha.example.org:4871", login: "a")
        context.insert(zeta)
        context.insert(alpha)
        try context.save()

        controller.attach(modelContext: context)
        controller.activeConnectionID = alpha.id

        #expect(controller.activeBookmarkedConnectionID() == alpha.id)
        #expect(controller.bookmarkMenuItems().map(\.name) == ["Alpha", "Zeta"])
    }

    @MainActor
    @Test
    func filesViewModelClearSearchLoadsRootWhenNoSavedBrowseStateExists() async {
        let runtime = TestData.makeRuntime()
        let service = TestFileService()
        let viewModel = FilesViewModel.empty()
        let docs = FileItem("Docs", path: "/Docs", type: .directory)
        let uploads = FileItem("Uploads", path: "/Uploads", type: .uploads)

        service.listedDirectories["/"] = [docs, uploads]
        viewModel.configure(fileService: service, runtime: runtime)

        await viewModel.clearSearch()

        #expect(viewModel.columns.count == 1)
        #expect(viewModel.columns.first?.path == "/")
        #expect(viewModel.columns.first?.items.map(\.path) == ["/Docs", "/Uploads"])
        #expect(viewModel.treeChildrenByPath["/"]?.map(\.path) == ["/Docs", "/Uploads"])
        #expect(service.subscribedPaths.contains("/"))
    }

    @MainActor
    @Test
    func filesViewModelReloadVisibleDirectoryRefreshesMatchingColumnAndTreeBranch() async {
        let runtime = TestData.makeRuntime()
        let service = TestFileService()
        let viewModel = FilesViewModel.empty()
        let docs = FileItem("Docs", path: "/Docs", type: .directory)
        let readme = FileItem("README.txt", path: "/Docs/README.txt", type: .file)
        let guide = FileItem("Guide.txt", path: "/Docs/Guide.txt", type: .file)

        service.listedDirectories["/Docs"] = [guide]
        viewModel.configure(fileService: service, runtime: runtime)
        viewModel.columns = [
            FileColumn(path: "/", items: [docs], selection: docs.id),
            FileColumn(path: "/Docs", items: [readme], selection: readme.id)
        ]
        viewModel.treeRootPath = "/"
        viewModel.treeChildrenByPath = ["/Docs": [readme]]
        viewModel.expandedTreePaths = ["/", "/Docs"]

        await viewModel.reloadVisibleDirectory("///Docs///")

        #expect(viewModel.columns[1].items.map(\.path) == ["/Docs/Guide.txt"])
        #expect(viewModel.columns[1].selection == nil)
        #expect(viewModel.treeChildrenByPath["/Docs"]?.map(\.path) == ["/Docs/Guide.txt"])
    }
}

private enum TestData {
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    static func makeChat(name: String) -> Chat {
        Chat(id: 1, name: name)
    }

    @MainActor
    static func makeUser(id: UInt32, nick: String) -> User {
        User(id: id, nick: nick, icon: Data(), idle: false)
    }

    struct IsolatedDefaults {
        let suiteName: String
        let defaults: UserDefaults
    }

    static func makeDefaults() -> IsolatedDefaults {
        let suiteName = "fr.read-write.Wired3.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedDefaults(suiteName: suiteName, defaults: defaults)
    }

    @MainActor
    static func makeRuntime() -> ConnectionRuntime {
        let controller = ConnectionController(socketClient: SocketClient())
        let runtime = ConnectionRuntime(id: UUID(), connectionController: controller)
        runtime.connection = AsyncConnection(withSpec: spec)
        return runtime
    }

    struct TransferManagerEnvironment {
        let manager: TransferManager
        let controller: ConnectionController
        let container: ModelContainer
        let context: ModelContext
    }

    @MainActor
    static func makeTransferManagerEnvironment() throws -> TransferManagerEnvironment {
        let controller = ConnectionController(socketClient: SocketClient())
        let manager = TransferManager(spec: spec, connectionController: controller)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transfer.self, configurations: configuration)
        let context = ModelContext(container)
        return TransferManagerEnvironment(
            manager: manager,
            controller: controller,
            container: container,
            context: context
        )
    }

    static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private final class TestFileService: @preconcurrency FileServiceProtocol {
    var listedDirectories: [String: [FileItem]] = [:]
    var listErrors: [String: Error] = [:]
    var searchResults: [FileItem] = []
    var searchError: Error?
    var subscribedPaths: [String] = []
    var unsubscribedPaths: [String] = []
    var unsubscribeErrors: [String: Error] = [:]
    var previewData: [String: Data] = [:]
    var previewErrors: [String: Error] = [:]

    func listDirectory(
        path: String,
        recursive: Bool,
        connection: AsyncConnection
    ) -> AsyncThrowingStream<FileItem, Error> {
        let items = listedDirectories[path] ?? []
        let error = listErrors[path]
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    func deleteFile(
        path: String,
        connection: AsyncConnection
    ) async throws { }

    func createDirectory(
        path: String,
        type: FileType,
        connection: AsyncConnection
    ) async throws { }

    func moveFile(
        from sourcePath: String,
        to destinationPath: String,
        connection: AsyncConnection
    ) async throws { }

    func setFileType(
        path: String,
        type: FileType,
        connection: AsyncConnection
    ) async throws { }

    func setFileComment(
        path: String,
        comment: String,
        connection: AsyncConnection
    ) async throws { }

    func setFileLabel(
        path: String,
        label: FileLabelValue,
        connection: AsyncConnection
    ) async throws { }

    func setFilePermissions(
        path: String,
        permissions: DropboxPermissions,
        connection: AsyncConnection
    ) async throws { }

    func setFileSyncPolicy(
        path: String,
        policy: SyncPolicyPayload,
        connection: AsyncConnection
    ) async throws { }

    func getFileInfo(
        path: String,
        connection: AsyncConnection
    ) async throws -> FileItem {
        FileItem(path.split(separator: "/").last.map(String.init) ?? path, path: path)
    }

    func previewFile(
        path: String,
        connection: AsyncConnection
    ) async throws -> Data {
        if let error = previewErrors[path] {
            throw error
        }
        return previewData[path] ?? Data()
    }

    func listUserNames(connection: AsyncConnection) async throws -> [String] { [] }
    func listGroupNames(connection: AsyncConnection) async throws -> [String] { [] }

    func subscribeDirectory(
        path: String,
        connection: AsyncConnection
    ) async throws {
        subscribedPaths.append(path)
    }

    func unsubscribeDirectory(
        path: String,
        connection: AsyncConnection
    ) async throws {
        unsubscribedPaths.append(path)
        if let error = unsubscribeErrors[path] {
            throw error
        }
    }

    func searchFiles(
        query: String,
        connection: AsyncConnection
    ) -> AsyncThrowingStream<FileItem, Error> {
        let results = searchResults
        let error = searchError
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for item in results {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }
}

private func oversizedPreviewItem(path: String) -> FileItem {
    var item = FileItem((path as NSString).lastPathComponent, path: path, type: .file)
    item.dataSize = RemoteQuickLookSupport.maxPreviewSizeBytes + 1
    return item
}
