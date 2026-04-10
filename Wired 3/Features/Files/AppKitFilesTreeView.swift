#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ObjectiveC
import WiredSwift

private final class TreeFileLabelDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = min(frameRect.width, frameRect.height) / 2
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func configure(label: FileLabelValue) {
        if label == .none {
            isHidden = true
            toolTip = nil
            return
        }

        isHidden = false
        layer?.backgroundColor = label.nsColor.cgColor
        toolTip = label.title
    }
}

private final class QuickLookOutlineView: NSOutlineView {
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

// swiftlint:disable type_body_length
struct AppKitFilesTreeView: NSViewRepresentable {
    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("TreeColumn")
        static let kind = NSUserInterfaceItemIdentifier("KindColumn")
        static let modified = NSUserInterfaceItemIdentifier("ModifiedColumn")
        static let size = NSUserInterfaceItemIdentifier("SizeColumn")
    }

    let rootPath: String
    let treeChildrenByPath: [String: [FileItem]]
    let expandedPaths: Set<String>
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    let connectionID: UUID
    let quickLookConnection: AsyncConnection?
    let transferManager: TransferManager
    let onDownloadTransferError: (FileItem, String) -> Void
    let onUploadURLs: ([URL], FileItem) -> Void
    @Binding var selectedPaths: Set<String>
    let onSelectionChange: (Set<String>) -> Void
    let onSetDirectoryExpanded: (String, Bool) -> Void
    let onDownloadSingleFile: (FileItem) -> Void
    let onOpenDirectory: (FileItem) -> Void
    let onRequestCreateFolder: () -> Void
    let onRequestUploadInDirectory: (FileItem) -> Void
    let onRequestDeleteSelection: () -> Void
    let onRequestDownloadSelection: () -> Void
    let onRequestGetInfo: (FileItem) -> Void
    let onRequestSyncNow: (FileItem) -> Void
    let onRequestActivateSync: (FileItem) -> Void
    let onRequestDeactivateSync: (FileItem) -> Void
    let syncPairStatusForPath: (String) -> SyncPairStatusDisplay
    let syncPairExistsForPath: (String) -> Bool
    let syncPairStatusVersion: Int
    let canSetFileType: Bool
    let canGetInfoForItem: (FileItem) -> Bool
    let canDownloadForItem: (FileItem) -> Bool
    let canDeleteForItem: (FileItem) -> Bool
    let canUploadToDirectory: (FileItem) -> Bool
    let canCreateFolderInDirectory: (FileItem) -> Bool
    let canSetLabel: Bool
    let onRequestSetLabel: ([FileItem], FileLabelValue) -> Void
    let savedScrollOffset: CGPoint
    let onScrollOffsetChange: (CGPoint) -> Void

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
        scrollView.automaticallyAdjustsContentInsets = false

        let outlineView = QuickLookOutlineView()
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.rowHeight = 26
        outlineView.usesAutomaticRowHeights = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        outlineView.target = context.coordinator
        outlineView.onQuickLook = { [weak coordinator = context.coordinator] in
            coordinator?.presentQuickLook()
        }
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = true

        let column = NSTableColumn(identifier: ColumnID.name)
        column.title = "Name"
        column.minWidth = 220
        column.width = 420
        column.resizingMask = .autoresizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let kindColumn = NSTableColumn(identifier: ColumnID.kind)
        kindColumn.title = "Kind"
        kindColumn.minWidth = 110
        kindColumn.width = 110
        kindColumn.resizingMask = .userResizingMask
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)
        outlineView.addTableColumn(kindColumn)

        let modifiedColumn = NSTableColumn(identifier: ColumnID.modified)
        modifiedColumn.title = "Modified"
        modifiedColumn.minWidth = 140
        modifiedColumn.width = 140
        modifiedColumn.resizingMask = .userResizingMask
        modifiedColumn.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: false)
        outlineView.addTableColumn(modifiedColumn)

        let sizeColumn = NSTableColumn(identifier: ColumnID.size)
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 100
        sizeColumn.width = 100
        sizeColumn.resizingMask = .userResizingMask
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        outlineView.addTableColumn(sizeColumn)

        let initialSortDescriptor = sortDescriptor(
            for: sortColumn,
            ascending: sortAscending,
            outlineView: outlineView
        ) ?? column.sortDescriptorPrototype
        outlineView.sortDescriptors = [initialSortDescriptor].compactMap { $0 }

        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        let menu = context.coordinator.makeContextMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        context.coordinator.scrollView = scrollView
        context.coordinator.applyHeaderInset()
        context.coordinator.syncFromModel(
            rootPath: rootPath,
            childrenByPath: treeChildrenByPath,
            expandedPaths: expandedPaths,
            selectedPaths: selectedPaths,
            syncPairStatusVersion: syncPairStatusVersion
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScrollChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        DispatchQueue.main.async {
            context.coordinator.restoreScrollPosition(savedScrollOffset)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyHeaderInset()
        context.coordinator.applySortDescriptorIfNeeded()
        context.coordinator.syncFromModel(
            rootPath: rootPath,
            childrenByPath: treeChildrenByPath,
            expandedPaths: expandedPaths,
            selectedPaths: selectedPaths,
            syncPairStatusVersion: syncPairStatusVersion
        )
    }

    private func sortDescriptor(
        for key: String,
        ascending: Bool,
        outlineView: NSOutlineView
    ) -> NSSortDescriptor? {
        guard let column = outlineView.tableColumns.first(where: { $0.sortDescriptorPrototype?.key == key }) else {
            return nil
        }

        if let prototype = column.sortDescriptorPrototype {
            return NSSortDescriptor(key: prototype.key, ascending: ascending)
        }

        return NSSortDescriptor(key: key, ascending: ascending)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        final class OutlineNode: NSObject {
            let item: FileItem
            var children: [OutlineNode] = []

            init(item: FileItem) {
                self.item = item
            }
        }

        var parent: AppKitFilesTreeView
        weak var outlineView: NSOutlineView?
        weak var scrollView: NSScrollView?
        private let rootNode = OutlineNode(item: FileItem("/", path: "/", type: .directory))
        private var nodesByPath: [String: OutlineNode] = [:]
        private var currentRootPath: String = "/"
        private var isApplyingSelectionFromSwiftUI = false
        private var isApplyingExpandedStateFromSwiftUI = false
        private var suppressDisclosureCallbacks = false
        private var pendingExpansionState: [String: Bool] = [:]
        private var contextDirectoryTarget: FileItem = FileItem("/", path: "/", type: .directory)
        private var contextSyncTarget: FileItem?
        private var clickedRowHadSelection = false
        private var lastChildrenPaths: [String: [String]] = [:]
        private var lastSyncPairStatusVersion: Int = -1
        private var currentChildrenByPath: [String: [FileItem]] = [:]
        private var lastExpandedPaths: Set<String> = ["/"]
        private var lastSelectedPaths: Set<String> = []
        private var activeSortKey: String = "name"
        private var activeSortAscending = true
        private var isRestoringScrollPosition = false
        private lazy var quickLookController = FilesQuickLookController(
            connectionID: parent.connectionID,
            sourceFrameProvider: { [weak self] path in
                self?.sourceFrameOnScreen(for: path)
            },
            windowProvider: { [weak self] in
                self?.outlineView?.window
            },
            connectionProvider: { [weak self] in
                self?.parent.quickLookConnection
            }
        )

        init(parent: AppKitFilesTreeView) {
            self.parent = parent
            self.currentRootPath = parent.rootPath
            self.activeSortKey = parent.sortColumn
            self.activeSortAscending = parent.sortAscending
            let normalizedRoot: String = {
                if parent.rootPath == "/" { return "/" }
                let trimmed = parent.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed.isEmpty ? "/" : "/" + trimmed
            }()
            let rootName = normalizedRoot == "/" ? "/" : (normalizedRoot as NSString).lastPathComponent
            self.contextDirectoryTarget = FileItem(rootName, path: normalizedRoot, type: .directory)
        }

        func applySortDescriptorIfNeeded() {
            guard let outlineView else { return }
            let desiredKey = parent.sortColumn
            let desiredAscending = parent.sortAscending
            let currentDescriptor = outlineView.sortDescriptors.first
            if currentDescriptor?.key == desiredKey, currentDescriptor?.ascending == desiredAscending {
                activeSortKey = desiredKey
                activeSortAscending = desiredAscending
                return
            }

            if outlineView.tableColumns.contains(where: { $0.sortDescriptorPrototype?.key == desiredKey }) {
                let descriptor = NSSortDescriptor(key: desiredKey, ascending: desiredAscending)
                outlineView.sortDescriptors = [descriptor]
                activeSortKey = desiredKey
                activeSortAscending = desiredAscending
                refreshTree(rootPath: currentRootPath, childrenByPath: currentChildrenByPath)
                applyExpandedState(lastExpandedPaths)
                updateSelection(lastSelectedPaths)
            } else if let fallback = outlineView.tableColumns.first?.sortDescriptorPrototype {
                outlineView.sortDescriptors = [fallback]
                activeSortKey = fallback.key ?? "name"
                activeSortAscending = fallback.ascending
            }
        }

        @objc func handleScrollChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            if isRestoringScrollPosition { return }
            parent.onScrollOffsetChange(normalizedScrollOffset(from: sv.contentView.bounds.origin))
        }

        func restoreScrollPosition(_ offset: CGPoint) {
            guard let scrollView, let outlineView else { return }

            isRestoringScrollPosition = true
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isRestoringScrollPosition = false
                }
            }

            let restoredOffset = denormalizedScrollOffset(from: offset)

            if offset.y <= 0.5 {
                if outlineView.numberOfRows > 0 {
                    outlineView.scrollRowToVisible(0)
                }
                scrollView.contentView.scroll(to: denormalizedScrollOffset(from: .zero))
            } else {
                scrollView.contentView.scroll(to: restoredOffset)
            }

            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func applyHeaderInset() {
            guard let scrollView, let outlineView else { return }
            let headerHeight = outlineView.headerView?.frame.height ?? 0
            scrollView.contentView.contentInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
        }

        private func normalizedScrollOffset(from rawOffset: CGPoint) -> CGPoint {
            CGPoint(x: rawOffset.x, y: max(0, rawOffset.y + topContentInset))
        }

        private func denormalizedScrollOffset(from normalizedOffset: CGPoint) -> CGPoint {
            CGPoint(x: normalizedOffset.x, y: normalizedOffset.y - topContentInset)
        }

        private var topContentInset: CGFloat {
            scrollView?.contentView.contentInsets.top ?? 0
        }

        private func isDirectory(_ item: FileItem) -> Bool {
            item.type.isDirectoryLike
        }

        private func sortedItems(_ items: [FileItem]) -> [FileItem] {
            items.sorted { lhs, rhs in
                let lhsDir = isDirectory(lhs)
                let rhsDir = isDirectory(rhs)
                if lhsDir != rhsDir { return lhsDir }

                let comparison: ComparisonResult = {
                    switch activeSortKey {
                    case "kind":
                        let lhsKind = lhs.type.description
                        let rhsKind = rhs.type.description
                        let kindOrder = lhsKind.localizedCaseInsensitiveCompare(rhsKind)
                        if kindOrder != ComparisonResult.orderedSame { return kindOrder }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    case "modified":
                        let lhsDate = lhs.modificationDate ?? .distantPast
                        let rhsDate = rhs.modificationDate ?? .distantPast
                        if lhsDate != rhsDate {
                            return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
                        }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    case "size":
                        let lhsSize = sortMetric(for: lhs)
                        let rhsSize = sortMetric(for: rhs)
                        if lhsSize != rhsSize {
                            return lhsSize < rhsSize ? .orderedAscending : .orderedDescending
                        }
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    default:
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    }
                }()

                if activeSortAscending {
                    return comparison != .orderedDescending
                } else {
                    return comparison == .orderedDescending
                }
            }
        }

        private func sortMetric(for item: FileItem) -> Int64 {
            if item.type == .file {
                return Int64(item.dataSize + item.rsrcSize)
            }
            if item.type.isDirectoryLike, item.hasDirectoryCount {
                return Int64(item.directoryCount)
            }
            return -1
        }

        private func fileSizeString(_ item: FileItem) -> String {
            if item.type.isDirectoryLike {
                guard item.hasDirectoryCount else { return "-" }
                return item.directoryCount == 1 ? "1 item" : "\(item.directoryCount) items"
            }
            guard item.type == .file else { return "-" }
            let total = Int64(item.dataSize + item.rsrcSize)
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }

        private func fileKindString(_ item: FileItem) -> String {
            item.type.description
        }

        private func modifiedDateString(_ item: FileItem) -> String {
            guard let date = item.modificationDate else { return "-" }
            return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        }

        private func childrenSnapshot(for items: [FileItem]) -> [String] {
            items.map { item in
                let modified = item.modificationDate?.timeIntervalSinceReferenceDate ?? -1
                return [
                    item.path,
                    item.name,
                    String(item.type.rawValue),
                    String(item.directoryCount),
                    String(item.hasDirectoryCount),
                    String(item.dataSize),
                    String(item.rsrcSize),
                    String(modified),
                    String(item.label.rawValue)
                ].joined(separator: "|")
            }
        }

        private func ancestorPaths(for path: String) -> [String] {
            var result: [String] = []
            var current = (path as NSString).deletingLastPathComponent
            while !current.isEmpty && current != "/" {
                result.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
            result.append("/")
            return result
        }

        private func ensureExpandedAncestors(in expanded: inout Set<String>) {
            let snapshot = Array(expanded)
            for path in snapshot {
                for ancestor in ancestorPaths(for: path) {
                    expanded.insert(ancestor)
                }
            }
        }

        private func treeDepth(for path: String) -> Int {
            if path == "/" { return 0 }
            return path.split(separator: "/").count
        }

        private func normalizedRemotePath(_ path: String) -> String {
            if path == "/" { return "/" }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed.isEmpty { return "/" }
            return "/" + trimmed
        }

        private func directoryItem(for path: String) -> FileItem {
            let normalized = normalizedRemotePath(path)
            let name = normalized == "/" ? "/" : (normalized as NSString).lastPathComponent
            return FileItem(name, path: normalized, type: .directory)
        }

        func refreshTree(rootPath: String, childrenByPath: [String: [FileItem]]) {
            currentChildrenByPath = childrenByPath
            lastChildrenPaths = childrenByPath.mapValues(childrenSnapshot(for:))
            nodesByPath.removeAll()
            currentRootPath = normalizedRemotePath(rootPath)

            func node(for item: FileItem) -> OutlineNode {
                if let existing = nodesByPath[item.path] { return existing }
                let created = OutlineNode(item: item)
                nodesByPath[item.path] = created
                return created
            }

            func buildChildren(parentPath: String, visiting: inout Set<String>) -> [OutlineNode] {
                guard !visiting.contains(parentPath) else { return [] }
                visiting.insert(parentPath)
                defer { visiting.remove(parentPath) }

                let children = sortedItems(childrenByPath[parentPath] ?? [])
                return children.map { childItem in
                    let childNode = node(for: childItem)
                    if isDirectory(childItem), childrenByPath[childItem.path] != nil {
                        childNode.children = buildChildren(parentPath: childItem.path, visiting: &visiting)
                    } else {
                        childNode.children = []
                    }
                    return childNode
                }
            }

            var visiting: Set<String> = []
            rootNode.children = buildChildren(parentPath: currentRootPath, visiting: &visiting)
            outlineView?.reloadData()
        }

        func syncFromModel(
            rootPath: String,
            childrenByPath: [String: [FileItem]],
            expandedPaths: Set<String>,
            selectedPaths: Set<String>,
            syncPairStatusVersion: Int
        ) {
            for (path, desiredExpanded) in pendingExpansionState {
                let modelExpanded = expandedPaths.contains(path)
                if modelExpanded == desiredExpanded {
                    pendingExpansionState.removeValue(forKey: path)
                }
            }

            var effectiveExpandedPaths = expandedPaths
            for (path, desiredExpanded) in pendingExpansionState {
                if desiredExpanded {
                    effectiveExpandedPaths.insert(path)
                } else {
                    effectiveExpandedPaths.remove(path)
                }
            }
            ensureExpandedAncestors(in: &effectiveExpandedPaths)

            suppressDisclosureCallbacks = true
            defer { suppressDisclosureCallbacks = false }

            let newRoot = normalizedRemotePath(rootPath)
            let treeChanged = newRoot != currentRootPath || treeStructureDidChange(childrenByPath)
            let syncStatusChanged = syncPairStatusVersion != lastSyncPairStatusVersion
            lastExpandedPaths = effectiveExpandedPaths
            lastSelectedPaths = selectedPaths
            if treeChanged {
                refreshTree(rootPath: rootPath, childrenByPath: childrenByPath)
            } else if syncStatusChanged {
                refreshSyncIndicators()
            }
            lastSyncPairStatusVersion = syncPairStatusVersion
            applyExpandedState(effectiveExpandedPaths)
            updateSelection(selectedPaths)
        }

        private func treeStructureDidChange(_ newChildren: [String: [FileItem]]) -> Bool {
            guard newChildren.count == lastChildrenPaths.count else { return true }
            for (key, items) in newChildren {
                guard let cached = lastChildrenPaths[key], cached == childrenSnapshot(for: items) else { return true }
            }
            return false
        }

        private func refreshSyncIndicators() {
            guard let outlineView else { return }
            for node in nodesByPath.values where node.item.type == .sync {
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }

        func applyExpandedState(_ expandedPaths: Set<String>) {
            guard let outlineView else { return }
            isApplyingExpandedStateFromSwiftUI = true
            defer { isApplyingExpandedStateFromSwiftUI = false }

            let expandableNodes = nodesByPath.values
                .filter { isDirectory($0.item) }
                .sorted {
                    let lhsDepth = treeDepth(for: $0.item.path)
                    let rhsDepth = treeDepth(for: $1.item.path)
                    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                    return $0.item.path < $1.item.path
                }

            for node in expandableNodes {
                let path = node.item.path
                if expandedPaths.contains(path), !outlineView.isItemExpanded(node) {
                    outlineView.expandItem(node, expandChildren: false)
                }
            }

            for node in expandableNodes.reversed() {
                let path = node.item.path
                if !expandedPaths.contains(path), outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node, collapseChildren: false)
                }
            }
        }

        func updateSelection(_ selectedPaths: Set<String>) {
            guard let outlineView else { return }
            var indexSet = IndexSet()
            for path in selectedPaths {
                guard let node = nodesByPath[path] else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    indexSet.insert(row)
                }
            }
            if outlineView.selectedRowIndexes != indexSet {
                isApplyingSelectionFromSwiftUI = true
                outlineView.selectRowIndexes(indexSet, byExtendingSelection: false)
                isApplyingSelectionFromSwiftUI = false
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = (item as? OutlineNode) ?? rootNode
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? OutlineNode) ?? rootNode
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? OutlineNode else { return false }
            return isDirectory(node.item)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? OutlineNode else { return nil }
            let item = node.item
            let columnID = tableColumn?.identifier ?? ColumnID.name

            if columnID == ColumnID.size {
                let id = NSUserInterfaceItemIdentifier("TreeSizeCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                    let cell = NSTableCellView()
                    cell.identifier = id
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.alignment = .right
                    tf.textColor = .secondaryLabelColor
                    tf.lineBreakMode = .byClipping
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                    return cell
                }()
                cell.textField?.stringValue = fileSizeString(item)
                return cell
            }

            if columnID == ColumnID.kind {
                let id = NSUserInterfaceItemIdentifier("TreeKindCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                    let cell = NSTableCellView()
                    cell.identifier = id
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.textColor = .secondaryLabelColor
                    tf.lineBreakMode = .byTruncatingTail
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                    return cell
                }()
                cell.textField?.stringValue = fileKindString(item)
                return cell
            }

            if columnID == ColumnID.modified {
                let id = NSUserInterfaceItemIdentifier("TreeModifiedCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                    let cell = NSTableCellView()
                    cell.identifier = id
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.textColor = .secondaryLabelColor
                    tf.lineBreakMode = .byTruncatingTail
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                    return cell
                }()
                cell.textField?.stringValue = modifiedDateString(item)
                return cell
            }

            let id = NSUserInterfaceItemIdentifier("TreeCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyUpOrDown
                cell.imageView = icon

                let labelDot = TreeFileLabelDotView(frame: .zero)
                labelDot.identifier = NSUserInterfaceItemIdentifier("FileLabelDot")
                labelDot.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(labelDot)

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
                    tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                    labelDot.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -32),
                    labelDot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    labelDot.widthAnchor.constraint(equalToConstant: 8),
                    labelDot.heightAnchor.constraint(equalToConstant: 8),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusSpinner.leadingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.trailingAnchor.constraint(equalTo: labelDot.leadingAnchor, constant: -8),
                    statusIcon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.widthAnchor.constraint(equalToConstant: 16),
                    statusIcon.heightAnchor.constraint(equalToConstant: 16),
                    statusSpinner.trailingAnchor.constraint(equalTo: labelDot.leadingAnchor, constant: -8),
                    statusSpinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusSpinner.widthAnchor.constraint(equalToConstant: 16),
                    statusSpinner.heightAnchor.constraint(equalToConstant: 16)
                ])
                return cell
            }()
            cell.textField?.stringValue = item.name
            cell.imageView?.image = remoteItemIconImage(for: item, size: 16)
            let labelDot = cell.subviews.compactMap { $0 as? TreeFileLabelDotView }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("FileLabelDot") })
            labelDot?.configure(label: item.label)

            let statusIcon = cell.subviews.compactMap { $0 as? NSImageView }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusIcon") })
            let statusSpinner = cell.subviews.compactMap { $0 as? NSProgressIndicator }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusSpinner") })
            let syncStatus: SyncPairStatusDisplay = item.type == .sync
                ? parent.syncPairStatusForPath(item.path)
                : .hidden
            switch syncStatus {
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
                cell.toolTip = syncStatus == .reconnecting ? "Sync reconnecting" : "Sync in progress"
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

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let nextDescriptor = outlineView.sortDescriptors.first
            activeSortKey = nextDescriptor?.key ?? "name"
            activeSortAscending = nextDescriptor?.ascending ?? true
            parent.sortColumn = activeSortKey
            parent.sortAscending = activeSortAscending
            refreshTree(rootPath: currentRootPath, childrenByPath: currentChildrenByPath)
            applyExpandedState(lastExpandedPaths)
            updateSelection(lastSelectedPaths)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            if isApplyingSelectionFromSwiftUI { return }
            guard let outlineView else { return }
            var paths = Set<String>()
            for index in outlineView.selectedRowIndexes {
                guard index >= 0,
                      let node = outlineView.item(atRow: index) as? OutlineNode else { continue }
                paths.insert(node.item.path)
            }
            parent.selectedPaths = paths
            parent.onSelectionChange(paths)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if isApplyingExpandedStateFromSwiftUI || suppressDisclosureCallbacks { return }
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
            pendingExpansionState[node.item.path] = true
            for ancestor in ancestorPaths(for: node.item.path) {
                pendingExpansionState[ancestor] = true
            }
            DispatchQueue.main.async {
                self.parent.onSetDirectoryExpanded(node.item.path, true)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if isApplyingExpandedStateFromSwiftUI || suppressDisclosureCallbacks { return }
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
            pendingExpansionState[node.item.path] = false
            let prefix = node.item.path == "/" ? "/" : node.item.path + "/"
            for (key, _) in pendingExpansionState where key.hasPrefix(prefix) {
                pendingExpansionState[key] = false
            }
            DispatchQueue.main.async {
                self.parent.onSetDirectoryExpanded(node.item.path, false)
            }
        }

        @objc
        func didDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }
            let item = node.item
            let isDir = isDirectory(item)
            if isDir {
                parent.onOpenDirectory(item)
            } else if parent.canDownloadForItem(item) {
                parent.onDownloadSingleFile(item)
            }
        }

        func presentQuickLook() {
            let orderedItems = visibleItemsInDisplayOrder()
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

        private func visibleItemsInDisplayOrder() -> [FileItem] {
            guard let outlineView else { return [] }
            return (0..<outlineView.numberOfRows).compactMap { row in
                (outlineView.item(atRow: row) as? OutlineNode)?.item
            }
        }

        private func primarySelectionPath() -> String? {
            guard let outlineView else { return nil }
            let selectedRows = outlineView.selectedRowIndexes
            if outlineView.clickedRow >= 0,
               selectedRows.contains(outlineView.clickedRow),
               let node = outlineView.item(atRow: outlineView.clickedRow) as? OutlineNode {
                return node.item.path
            }
            if let first = selectedRows.first,
               let node = outlineView.item(atRow: first) as? OutlineNode {
                return node.item.path
            }
            return nil
        }

        private func sourceFrameOnScreen(for path: String) -> NSRect? {
            guard let outlineView,
                  let node = nodesByPath[path] else { return nil }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return nil }
            let rowRect = outlineView.rect(ofRow: row)
            guard !rowRect.isEmpty else { return nil }
            let rectInWindow = outlineView.convert(rowRect, to: nil)
            return outlineView.window?.convertToScreen(rectInWindow)
        }

        private func selectedItems() -> [FileItem] {
            guard let outlineView else { return [] }
            let selectedRows = outlineView.selectedRowIndexes.compactMap { row -> Int? in
                row >= 0 ? row : nil
            }
            return selectedRows.compactMap { row -> FileItem? in
                (outlineView.item(atRow: row) as? OutlineNode)?.item
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem itemRef: Any) -> NSPasteboardWriting? {
            guard let node = itemRef as? OutlineNode else { return nil }
            let item = node.item
            let isDir = isDirectory(item)
            let fileType: String
            if isDir {
                fileType = UTType.folder.identifier
            } else {
                let ext = (dragExportFileName(for: item) as NSString).pathExtension
                fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
            }

            let delegate = DragPlaceholderPromiseDelegate(item: item)
            delegate.connectionID = parent.connectionID
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

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        private func finderDroppedURLs(from info: NSDraggingInfo) -> [URL] {
            let classes: [AnyClass] = [NSURL.self]
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return info.draggingPasteboard.readObjects(forClasses: classes, options: options) as? [URL] ?? []
        }

        private func dropDestination(for itemRef: Any?) -> FileItem? {
            guard let node = itemRef as? OutlineNode else {
                return directoryItem(for: currentRootPath)
            }

            let item = node.item
            guard isDirectory(item) else { return nil }
            return item
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let urls = finderDroppedURLs(from: info)
            guard !urls.isEmpty else { return [] }
            guard let destination = dropDestination(for: item) else { return [] }

            if item == nil || destination.path == currentRootPath {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else {
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let urls = finderDroppedURLs(from: info)
            guard !urls.isEmpty else { return false }
            guard let destination = dropDestination(for: item) else { return false }

            DispatchQueue.main.async {
                self.parent.onUploadURLs(urls, destination)
            }
            return true
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            var item = menu.addItem(withTitle: "Get Info", action: #selector(contextGetInfo), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            
            item = menu.addItem(withTitle: "Quick Look", action: #selector(contextQuickLook), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            
            menu.addItem(NSMenuItem.separator())
            item = menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            
            item = menu.addItem(withTitle: "Download", action: #selector(contextDownload), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            
            item = menu.addItem(withTitle: "Upload…", action: #selector(contextUpload), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil)

            menu.addItem(makeLabelSubmenuItem(target: self))

            menu.addItem(NSMenuItem.separator())
            item = menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            
            menu.addItem(NSMenuItem.separator())
            let statusItem = menu.addItem(withTitle: "Sync Status: Pair inactive", action: nil, keyEquivalent: "")
            statusItem.tag = SyncContextMenuItemTag.status
            let toggleItem = menu.addItem(withTitle: "Activate Sync Pair", action: #selector(contextToggleSyncPair), keyEquivalent: "")
            toggleItem.tag = SyncContextMenuItemTag.toggle
            toggleItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            
            let syncNowItem = menu.addItem(withTitle: "Sync Now", action: #selector(contextSyncNow), keyEquivalent: "")
            syncNowItem.tag = SyncContextMenuItemTag.syncNow
            syncNowItem.image = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise", accessibilityDescription: nil)
            
            for item in menu.items {
                item.target = self
            }
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { return }
            let point = outlineView.convert(outlineView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let row = outlineView.row(at: point)
            let hasSelectionBefore = !outlineView.selectedRowIndexes.isEmpty

            if row >= 0 {
                clickedRowHadSelection = outlineView.selectedRowIndexes.contains(row)
                if !clickedRowHadSelection {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }

                if let node = outlineView.item(atRow: row) as? OutlineNode {
                    let item = node.item
                    if isDirectory(item) {
                        contextDirectoryTarget = item
                    } else {
                        let parentPath = item.path.stringByDeletingLastPathComponent
                        contextDirectoryTarget = FileItem(parentPath.lastPathComponent, path: parentPath, type: .directory)
                    }
                } else {
                    contextDirectoryTarget = directoryItem(for: currentRootPath)
                }
            } else {
                clickedRowHadSelection = false
                if hasSelectionBefore {
                    outlineView.deselectAll(nil)
                }
                contextDirectoryTarget = directoryItem(for: currentRootPath)
            }

            let selectedRows = outlineView.selectedRowIndexes.compactMap { row -> Int? in
                row >= 0 ? row : nil
            }
            let selectedItems = selectedRows.compactMap { row -> FileItem? in
                (outlineView.item(atRow: row) as? OutlineNode)?.item
            }
            if let quickLookItem = menu.item(withTitle: "Quick Look") {
                quickLookItem.isEnabled = selectedItems.contains(where: { RemoteQuickLookSupport.isPreviewable($0) })
            }
            if let downloadItem = menu.item(withTitle: "Download") {
                downloadItem.isEnabled = selectedItems.contains(where: { parent.canDownloadForItem($0) })
            }
            if let deleteItem = menu.item(withTitle: "Delete") {
                deleteItem.isEnabled = selectedItems.contains(where: { parent.canDeleteForItem($0) })
            }
            if let uploadItem = menu.item(withTitle: "Upload…") {
                uploadItem.isEnabled = parent.canUploadToDirectory(contextDirectoryTarget)
            }
            if let infoItem = menu.item(withTitle: "Get Info") {
                let canGetSelectedInfo: Bool = {
                    guard selectedItems.count == 1, let item = selectedItems.first else { return false }
                    return parent.canGetInfoForItem(item)
                }()
                infoItem.isEnabled = canGetSelectedInfo
            }
            let selectedSyncItem: FileItem? = {
                guard selectedItems.count == 1, let item = selectedItems.first, item.type == .sync else { return nil }
                return item
            }()
            contextSyncTarget = selectedSyncItem
            let syncState: SyncPairStatusDisplay = selectedSyncItem.map { parent.syncPairStatusForPath($0.path) } ?? .hidden
            let pairExists = selectedSyncItem.map { parent.syncPairExistsForPath($0.path) } ?? false

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
            if let syncItem = menu.item(withTag: SyncContextMenuItemTag.syncNow) {
                let canSyncNow = selectedSyncItem != nil && pairExists && syncState != .checking
                syncItem.isHidden = selectedSyncItem == nil
                syncItem.isEnabled = canSyncNow
            }
            if let newFolderItem = menu.item(withTitle: "New Folder") {
                newFolderItem.isEnabled = parent.canCreateFolderInDirectory(contextDirectoryTarget)
            }
            if let labelItem = menu.item(withTag: LabelContextMenuItemTag.submenu) {
                labelItem.isEnabled = parent.canSetLabel && !selectedItems.isEmpty
            }
        }

        @objc private func contextQuickLook() { presentQuickLook() }
        @objc private func contextDownload() { parent.onRequestDownloadSelection() }
        @objc private func contextDelete() { parent.onRequestDeleteSelection() }
        @objc private func contextUpload() {
            guard parent.canUploadToDirectory(contextDirectoryTarget) else { return }
            parent.onRequestUploadInDirectory(contextDirectoryTarget)
        }
        @objc private func contextGetInfo() {
            guard let item = contextSyncTarget ?? selectedItem() else { return }
            guard parent.canGetInfoForItem(item) else { return }
            parent.onRequestGetInfo(item)
        }
        @objc private func contextSyncNow() {
            guard let item = contextSyncTarget else { return }
            parent.onRequestSyncNow(item)
        }
        @objc private func contextToggleSyncPair() {
            guard let item = contextSyncTarget, item.type == .sync else { return }
            if parent.syncPairStatusForPath(item.path) == .checking {
                return
            }
            if parent.syncPairExistsForPath(item.path) {
                parent.onRequestDeactivateSync(item)
            } else {
                parent.onRequestActivateSync(item)
            }
        }
        private func selectedItem() -> FileItem? {
            let items = selectedItems()
            guard items.count == 1 else { return nil }
            return items.first
        }
        @objc private func contextNewFolder() {
            guard parent.canCreateFolderInDirectory(contextDirectoryTarget) else { return }
            parent.onRequestCreateFolder()
        }

        @objc func contextSetLabel(_ sender: NSMenuItem) {
            let rawValue = UInt32(sender.tag - LabelContextMenuItemTag.itemBase)
            let label = FileLabelValue(rawValue: rawValue) ?? .none
            let targets = selectedItems()
            guard !targets.isEmpty else { return }
            parent.onRequestSetLabel(targets, label)
        }
    }
}

private extension FileLabelValue {
    var nsColor: NSColor {
        switch self {
        case .none:
            return .secondaryLabelColor
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .gray:
            return .systemGray
        }
    }
}
// swiftlint:enable type_body_length
#endif
