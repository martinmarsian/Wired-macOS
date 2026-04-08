#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ObjectiveC
import WiredSwift

private final class QuickLookTableView: NSTableView {
    var onQuickLook: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           event.keyCode == 49 {
            onQuickLook?()
            return
        }

        super.keyDown(with: event)
    }
}

struct AppKitFileColumnTableView: NSViewRepresentable {
    let bookmarkID: UUID
    let quickLookConnection: AsyncConnection?
    let transferManager: TransferManager
    let onDownloadTransferError: (FileItem, String) -> Void
    let column: FileColumn
    let selectedPaths: Set<String>
    let onSelectionChange: (Set<String>, String?) -> Void
    let onDownloadSingleFile: (FileItem) -> Void
    let onUploadURLs: ([URL], FileItem) -> Void
    let onMoveRemoteItem: (_ sourcePath: String, _ destinationDirectory: FileItem) async throws -> Void
    let onRequestCreateFolder: (FileItem) -> Void
    let onRequestUploadInDirectory: (FileItem) -> Void
    let onRequestDeleteSelection: ([FileItem]) -> Void
    let onRequestDownloadSelection: ([FileItem]) -> Void
    let onRequestGetInfo: (FileItem) -> Void
    let onRequestSyncNow: (FileItem) -> Void
    let onRequestActivateSync: (FileItem) -> Void
    let onRequestDeactivateSync: (FileItem) -> Void
    let syncPairStatusForItem: (FileItem) -> SyncPairStatusDisplay
    let syncPairExistsForItem: (FileItem) -> Bool
    let syncPairStatusVersion: Int
    let canSetFileType: Bool
    let canGetInfoForItem: (FileItem) -> Bool
    let canDownloadForItem: (FileItem) -> Bool
    let canDeleteForItem: (FileItem) -> Bool
    let canUploadToDirectory: (FileItem) -> Bool
    let canCreateFolderInDirectory: (FileItem) -> Bool
    let savedScrollOffset: CGFloat
    let onScrollOffsetChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = QuickLookTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 26
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([.fileURL, wiredRemotePathPasteboardType])
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        tableView.onQuickLook = { [weak coordinator = context.coordinator] in
            coordinator?.presentQuickLook()
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColumnName"))
        column.title = "Name"
        column.minWidth = 220
        column.width = 300
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        let menu = context.coordinator.makeContextMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.syncFromModel(items: self.column.items, selectedPaths: selectedPaths, syncPairStatusVersion: syncPairStatusVersion)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScrollChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let offsetToRestore = CGPoint(x: 0, y: savedScrollOffset)
        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: offsetToRestore)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncFromModel(items: self.column.items, selectedPaths: selectedPaths, syncPairStatusVersion: syncPairStatusVersion)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: AppKitFileColumnTableView
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var items: [FileItem] = []
        private var byPath: [String: Int] = [:]
        private var lastItemPaths: [String] = []
        private var lastSyncPairStatusVersion: Int = -1
        private var isApplyingSelectionFromSwiftUI = false
        private var contextDirectoryTarget: FileItem
        private lazy var quickLookController = FilesQuickLookController(
            connectionID: parent.bookmarkID,
            sourceFrameProvider: { [weak self] path in
                self?.sourceFrameOnScreen(for: path)
            },
            windowProvider: { [weak self] in
                self?.tableView?.window
            },
            connectionProvider: { [weak self] in
                self?.parent.quickLookConnection
            }
        )

        init(parent: AppKitFileColumnTableView) {
            self.parent = parent
            self.contextDirectoryTarget = FileItem((parent.column.path as NSString).lastPathComponent, path: parent.column.path, type: .directory)
        }

        @objc func handleScrollChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            parent.onScrollOffsetChange(sv.contentView.bounds.origin.y)
        }

        private func isDirectory(_ item: FileItem) -> Bool {
            item.type.isDirectoryLike
        }

        private func columnDirectory() -> FileItem {
            FileItem((parent.column.path as NSString).lastPathComponent, path: parent.column.path, type: .directory)
        }

        private func desiredColumnWidth(for items: [FileItem]) -> CGFloat {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let longestTextWidth = items.reduce(CGFloat(0)) { partial, item in
                let width = (item.name as NSString).size(withAttributes: [.font: font]).width
                return max(partial, width)
            }
            let paddedWidth = longestTextWidth + 64 + 24
            return min(max(220, ceil(paddedWidth)), 420)
        }

        func syncFromModel(items: [FileItem], selectedPaths: Set<String>, syncPairStatusVersion: Int) {
            let newPaths = items.map(\.path)
            let listChanged = newPaths != lastItemPaths
            let syncStatusChanged = syncPairStatusVersion != lastSyncPairStatusVersion
            lastItemPaths = newPaths
            lastSyncPairStatusVersion = syncPairStatusVersion
            self.items = items
            var map: [String: Int] = [:]
            for (index, item) in items.enumerated() {
                map[item.path] = index
            }
            self.byPath = map
            contextDirectoryTarget = columnDirectory()
            if let tableColumn = tableView?.tableColumns.first {
                tableColumn.width = desiredColumnWidth(for: items)
            }
            if listChanged {
                tableView?.reloadData()
            } else if syncStatusChanged {
                let syncRows = IndexSet(items.indices.filter { items[$0].type == .sync })
                if !syncRows.isEmpty {
                    tableView?.reloadData(forRowIndexes: syncRows, columnIndexes: IndexSet(integer: 0))
                }
            }
            updateSelection(selectedPaths)
        }

        private func updateSelection(_ selectedPaths: Set<String>) {
            guard let tableView else { return }
            var indexSet = IndexSet()
            for path in selectedPaths {
                if let row = byPath[path] {
                    indexSet.insert(row)
                }
            }

            if tableView.selectedRowIndexes != indexSet {
                isApplyingSelectionFromSwiftUI = true
                tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
                isApplyingSelectionFromSwiftUI = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < items.count else { return nil }
            let item = items[row]
            let id = NSUserInterfaceItemIdentifier("ColumnCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyUpOrDown
                cell.imageView = icon

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(tf)
                cell.textField = tf
                cell.addSubview(icon)

                let statusIcon = NSImageView()
                statusIcon.identifier = NSUserInterfaceItemIdentifier("SyncStatusIcon")
                statusIcon.translatesAutoresizingMaskIntoConstraints = false
                statusIcon.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(statusIcon)

                let statusSpinner = NSProgressIndicator()
                statusSpinner.identifier = NSUserInterfaceItemIdentifier("SyncStatusSpinner")
                statusSpinner.translatesAutoresizingMaskIntoConstraints = false
                statusSpinner.controlSize = .regular
                statusSpinner.style = .spinning
                statusSpinner.isDisplayedWhenStopped = false
                cell.addSubview(statusSpinner)

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusSpinner.leadingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    statusIcon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.widthAnchor.constraint(equalToConstant: 16),
                    statusIcon.heightAnchor.constraint(equalToConstant: 16),
                    statusSpinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    statusSpinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusSpinner.widthAnchor.constraint(equalToConstant: 16),
                    statusSpinner.heightAnchor.constraint(equalToConstant: 16)
                ])
                return cell
            }()

            cell.textField?.stringValue = item.name
            cell.imageView?.image = remoteItemIconImage(for: item, size: 16)
            let statusIcon = cell.subviews.compactMap { $0 as? NSImageView }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusIcon") })
            let statusSpinner = cell.subviews.compactMap { $0 as? NSProgressIndicator }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusSpinner") })
            switch parent.syncPairStatusForItem(item) {
            case .hidden:
                statusIcon?.isHidden = true
                statusSpinner?.stopAnimation(nil)
                cell.toolTip = nil
            case .checking:
                statusIcon?.isHidden = true
                statusSpinner?.isHidden = false
                statusSpinner?.startAnimation(nil)
                cell.toolTip = "Sync status pending"
            case .paused:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .secondaryLabelColor
                statusIcon?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Pair paused")
                cell.toolTip = "Sync paused"
            case .connecting, .syncing, .reconnecting:
                statusIcon?.isHidden = true
                statusSpinner?.isHidden = false
                statusSpinner?.startAnimation(nil)
                cell.toolTip = parent.syncPairStatusForItem(item) == .reconnecting ? "Sync reconnecting" : "Sync in progress"
            case .connected:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .systemGreen
                statusIcon?.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: "Pair connected")
                cell.toolTip = "Sync connected"
            case .error(let message):
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .systemOrange
                statusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Pair error")
                cell.toolTip = message ?? "Sync error"
            case .inactive:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .secondaryLabelColor
                statusIcon?.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: "Pair inactive")
                cell.toolTip = "Sync inactive"
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            if isApplyingSelectionFromSwiftUI { return }
            guard let tableView else { return }

            let selectedRows = tableView.selectedRowIndexes
            var paths = Set<String>()
            for row in selectedRows where row >= 0 && row < items.count {
                paths.insert(items[row].path)
            }

            let primary: String? = {
                if tableView.clickedRow >= 0 && tableView.clickedRow < items.count && selectedRows.contains(tableView.clickedRow) {
                    return items[tableView.clickedRow].path
                }
                if let first = selectedRows.first, first >= 0 && first < items.count {
                    return items[first].path
                }
                return nil
            }()

            parent.onSelectionChange(paths, primary)
        }

        @objc
        func didDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0 && row < items.count else { return }
            let item = items[row]
            if !isDirectory(item), parent.canDownloadForItem(item) {
                parent.onDownloadSingleFile(item)
            }
        }

        func presentQuickLook() {
            let orderedItems = items
            let selectedPaths = Set(selectedItems().map(\.path))
            let preferredPath = primarySelectionPath()
            Task { @MainActor [quickLookController] in
                quickLookController.present(
                    orderedItems: orderedItems,
                    selectedPaths: selectedPaths,
                    preferredPath: preferredPath
                )
            }
        }

        private func primarySelectionPath() -> String? {
            guard let tableView else { return nil }
            let selectedRows = tableView.selectedRowIndexes
            if tableView.clickedRow >= 0,
               tableView.clickedRow < items.count,
               selectedRows.contains(tableView.clickedRow) {
                return items[tableView.clickedRow].path
            }
            if let first = selectedRows.first, first >= 0, first < items.count {
                return items[first].path
            }
            return nil
        }

        private func sourceFrameOnScreen(for path: String) -> NSRect? {
            guard let tableView,
                  let row = byPath[path],
                  row >= 0 else { return nil }
            let rowRect = tableView.rect(ofRow: row)
            guard !rowRect.isEmpty else { return nil }
            let rectInWindow = tableView.convert(rowRect, to: nil)
            return tableView.window?.convertToScreen(rectInWindow)
        }

        func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
            let selectedRows = rowIndexes.compactMap { ($0 >= 0 && $0 < items.count) ? $0 : nil }
            guard !selectedRows.isEmpty else { return false }

            let remotePaths = selectedRows.map { items[$0].path }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(remotePaths.joined(separator: "\n"), forType: wiredRemotePathPasteboardType)
            pboard.clearContents()
            pboard.writeObjects([pasteboardItem])
            return true
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0 && row < items.count else { return nil }
            let item = items[row]
            let isDir = isDirectory(item)
            let fileType: String
            if isDir {
                fileType = UTType.folder.identifier
            } else {
                let ext = (dragExportFileName(for: item) as NSString).pathExtension
                fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
            }

            let delegate = DragPlaceholderPromiseDelegate(item: item)
            delegate.connectionID = parent.bookmarkID
            delegate.transferManager = parent.transferManager
            delegate.onDownloadTransferError = parent.onDownloadTransferError
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
            objc_setAssociatedObject(
                provider,
                &dragPromiseDelegateAssociationKey,
                delegate,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return provider
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : .copy
        }

        private func finderDroppedURLs(from info: NSDraggingInfo) -> [URL] {
            let classes: [AnyClass] = [NSURL.self]
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return info.draggingPasteboard.readObjects(forClasses: classes, options: options) as? [URL] ?? []
        }

        private func remoteDroppedPaths(from info: NSDraggingInfo) -> [String] {
            let raw = info.draggingPasteboard.string(forType: wiredRemotePathPasteboardType) ?? ""
            return raw
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        }

        private func destinationForDrop(proposedRow row: Int) -> FileItem? {
            if row >= 0, row < items.count {
                let item = items[row]
                if isDirectory(item) {
                    return item
                }
            }
            return columnDirectory()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let destination = destinationForDrop(proposedRow: row) else { return [] }

            if !finderDroppedURLs(from: info).isEmpty {
                if row >= 0 {
                    tableView.setDropRow(row, dropOperation: .on)
                } else {
                    tableView.setDropRow(-1, dropOperation: .above)
                }
                return .copy
            }

            let remotePaths = remoteDroppedPaths(from: info)
            guard !remotePaths.isEmpty else { return [] }
            if remotePaths.contains(where: { $0 == destination.path || destination.path.hasPrefix($0 + "/") }) {
                return []
            }
            if row >= 0 {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .above)
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let destination = destinationForDrop(proposedRow: row) else { return false }

            let urls = finderDroppedURLs(from: info)
            if !urls.isEmpty {
                DispatchQueue.main.async {
                    self.parent.onUploadURLs(urls, destination)
                }
                return true
            }

            let remotePaths = remoteDroppedPaths(from: info)
            guard !remotePaths.isEmpty else { return false }
            for source in remotePaths {
                Task {
                    do {
                        try await parent.onMoveRemoteItem(source, destination)
                    } catch {
                    }
                }
            }
            return true
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Quick Look", action: #selector(contextQuickLook), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Download", action: #selector(contextDownload), keyEquivalent: "")
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            menu.addItem(withTitle: "Upload…", action: #selector(contextUpload), keyEquivalent: "")
            menu.addItem(withTitle: "Get Info", action: #selector(contextGetInfo), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            let statusItem = menu.addItem(withTitle: "Sync Status: Pair inactive", action: nil, keyEquivalent: "")
            statusItem.tag = SyncContextMenuItemTag.status
            let toggleItem = menu.addItem(withTitle: "Activate Sync Pair", action: #selector(contextToggleSyncPair), keyEquivalent: "")
            toggleItem.tag = SyncContextMenuItemTag.toggle
            let syncNowItem = menu.addItem(withTitle: "Sync Now", action: #selector(contextSyncNow), keyEquivalent: "")
            syncNowItem.tag = SyncContextMenuItemTag.syncNow
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
            for item in menu.items {
                item.target = self
            }
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            let row = tableView.clickedRow

            if row >= 0 && row < items.count {
                if !tableView.selectedRowIndexes.contains(row) {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }

                let item = items[row]
                if isDirectory(item) {
                    contextDirectoryTarget = item
                } else {
                    contextDirectoryTarget = columnDirectory()
                }
            } else {
                if !tableView.selectedRowIndexes.isEmpty {
                    tableView.deselectAll(nil)
                }
                contextDirectoryTarget = columnDirectory()
            }

            let selected = selectedItems()
            menu.item(withTitle: "Quick Look")?.isEnabled = selected.contains(where: { RemoteQuickLookSupport.isPreviewable($0) })
            menu.item(withTitle: "Download")?.isEnabled = selected.contains(where: { parent.canDownloadForItem($0) })
            menu.item(withTitle: "Delete")?.isEnabled = selected.contains(where: { parent.canDeleteForItem($0) })
            menu.item(withTitle: "Upload…")?.isEnabled = parent.canUploadToDirectory(contextDirectoryTarget)
            let canGetSelectedInfo: Bool = {
                guard selected.count == 1, let item = selected.first else { return false }
                return parent.canGetInfoForItem(item)
            }()
            menu.item(withTitle: "Get Info")?.isEnabled = canGetSelectedInfo
            let selectedSyncItem: FileItem? = {
                guard selected.count == 1, let item = selected.first, item.type == .sync else { return nil }
                return item
            }()
            let syncState: SyncPairStatusDisplay = selectedSyncItem.map { parent.syncPairStatusForItem($0) } ?? .hidden
            let pairExists = selectedSyncItem.map { parent.syncPairExistsForItem($0) } ?? false
            if let syncStatusItem = menu.item(withTag: SyncContextMenuItemTag.status) {
                switch syncState {
                case .paused:
                    syncStatusItem.title = "Sync Status: Paused"
                case .connecting:
                    syncStatusItem.title = "Sync Status: Connecting…"
                case .connected:
                    syncStatusItem.title = "Sync Status: Connected"
                case .syncing:
                    syncStatusItem.title = "Sync Status: Syncing…"
                case .reconnecting:
                    syncStatusItem.title = "Sync Status: Reconnecting…"
                case .error(let message):
                    syncStatusItem.title = "Sync Status: Error\(message.map { " - \($0)" } ?? "")"
                case .inactive:
                    syncStatusItem.title = "Sync Status: Pair inactive"
                case .checking:
                    syncStatusItem.title = "Sync Status: Updating…"
                case .hidden:
                    syncStatusItem.title = "Sync Status: Pair inactive"
                }
                syncStatusItem.isHidden = selectedSyncItem == nil
                syncStatusItem.isEnabled = false
            }
            if let toggleItem = menu.item(withTag: SyncContextMenuItemTag.toggle) {
                if selectedSyncItem == nil {
                    toggleItem.title = "Activate Sync Pair"
                    toggleItem.isEnabled = false
                } else if syncState == .checking {
                    toggleItem.title = pairExists ? "Deactivate Sync Pair" : "Activate Sync Pair"
                    toggleItem.isEnabled = false
                } else if pairExists {
                    toggleItem.title = "Deactivate Sync Pair"
                    toggleItem.isEnabled = true
                } else {
                    toggleItem.title = "Activate Sync Pair"
                    toggleItem.isEnabled = true
                }
                toggleItem.isHidden = selectedSyncItem == nil
            }
            menu.item(withTag: SyncContextMenuItemTag.syncNow)?.isHidden = selectedSyncItem == nil
            menu.item(withTag: SyncContextMenuItemTag.syncNow)?.isEnabled = selectedSyncItem != nil && pairExists && syncState != .checking
            menu.item(withTitle: "New Folder")?.isEnabled = parent.canCreateFolderInDirectory(contextDirectoryTarget)
        }

        private func selectedItems() -> [FileItem] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { row in
                guard row >= 0 && row < items.count else { return nil }
                return items[row]
            }
        }

        @objc private func contextQuickLook() {
            presentQuickLook()
        }

        @objc private func contextDownload() {
            let selected = selectedItems().filter { parent.canDownloadForItem($0) }
            guard !selected.isEmpty else { return }
            parent.onRequestDownloadSelection(selected)
        }

        @objc private func contextDelete() {
            let selected = selectedItems().filter { parent.canDeleteForItem($0) }
            guard !selected.isEmpty else { return }
            parent.onRequestDeleteSelection(selected)
        }

        @objc private func contextUpload() {
            guard parent.canUploadToDirectory(contextDirectoryTarget) else { return }
            parent.onRequestUploadInDirectory(contextDirectoryTarget)
        }

        @objc private func contextGetInfo() {
            guard let item = selectedItems().first else { return }
            guard parent.canGetInfoForItem(item) else { return }
            parent.onRequestGetInfo(item)
        }

        @objc private func contextSyncNow() {
            guard let item = selectedItems().first, item.type == .sync else { return }
            parent.onRequestSyncNow(item)
        }

        @objc private func contextToggleSyncPair() {
            guard let item = selectedItems().first, item.type == .sync else { return }
            if parent.syncPairStatusForItem(item) == .checking {
                return
            }
            if parent.syncPairExistsForItem(item) {
                parent.onRequestDeactivateSync(item)
            } else {
                parent.onRequestActivateSync(item)
            }
        }

        @objc private func contextNewFolder() {
            guard parent.canCreateFolderInDirectory(contextDirectoryTarget) else { return }
            parent.onRequestCreateFolder(contextDirectoryTarget)
        }
    }
}
#endif
