import SwiftUI
import WiredSwift

struct FilesTreeView: View {
    let connectionID: UUID
    @ObservedObject var filesViewModel: FilesViewModel
    @Binding var sortColumn: String
    @Binding var sortAscending: Bool
    @EnvironmentObject private var transfers: TransferManager
    @Environment(\.colorScheme) private var colorScheme

    let onRequestCreateFolder: (FileItem) -> Void
    let onPrimarySelectionChange: (String?) -> Void
    let onSelectionItemsChange: ([FileItem]) -> Void
    let onOpenDirectory: (FileItem) -> Void
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
    let canDropRemoteItem: (String, FileItem, Bool) -> Bool
    let canSetLabel: Bool
    let onRequestSetLabel: ([FileItem], FileLabelValue) -> Void
    let onUploadURLs: ([URL], FileItem) -> Void
    let onMoveRemoteItem: (_ sourcePath: String, _ destinationDirectory: FileItem, _ link: Bool) async throws -> Void
    @State private var finderDropTargetPath: String?
    @State private var selectedPaths: Set<String> = []

    var body: some View {
        #if os(macOS)
        AppKitFilesTreeView(
            rootPath: filesViewModel.treeRootPath,
            treeChildrenByPath: filesViewModel.treeChildrenByPath,
            expandedPaths: filesViewModel.expandedTreePaths,
            sortColumn: $sortColumn,
            sortAscending: $sortAscending,
            connectionID: connectionID,
            quickLookConnection: filesViewModel.activeConnection,
            transferManager: transfers,
            onDownloadTransferError: { item, message in
                filesViewModel.error = WiredError(
                    withTitle: "Download Error",
                    message: "Unable to download \"\(item.name)\":\n\(message)"
                )
            },
            onUploadURLs: onUploadURLs,
            onMoveRemoteItem: onMoveRemoteItem,
            selectedPaths: $selectedPaths,
            onSelectionChange: { newSelection in
                let orderedNodes = filesViewModel.visibleTreeNodes()
                let orderedPaths = orderedNodes.map { $0.item.path }
                let primaryPath = orderedPaths.first(where: { newSelection.contains($0) })
                onPrimarySelectionChange(primaryPath)
                onSelectionItemsChange(selectedItems(from: newSelection))

                if let primaryPath {
                    filesViewModel.treeSelectionPath = primaryPath
                } else {
                    filesViewModel.treeSelectionPath = nil
                }
            },
            onSetDirectoryExpanded: { path, expanded in
                Task { await filesViewModel.setTreeExpansion(for: path, expanded: expanded) }
            },
            onDownloadSingleFile: { item in
                guard canDownloadForItem(item) else { return }
                onRequestDownloadSelection([item])
            },
            onOpenDirectory: { directory in
                onOpenDirectory(directory)
            },
            onRequestCreateFolder: {
                let target = contextMenuTargetDirectory()
                guard canCreateFolderInDirectory(target) else { return }
                onRequestCreateFolder(target)
            },
            onRequestUploadInDirectory: { directory in
                guard canUploadToDirectory(directory) else { return }
                onRequestUploadInDirectory(directory)
            },
            onRequestDeleteSelection: {
                let selected = selectedItems(from: selectedPaths)
                guard !selected.isEmpty else { return }
                let deletable = selected.filter { canDeleteForItem($0) }
                guard !deletable.isEmpty else { return }
                onRequestDeleteSelection(deletable)
            },
            onRequestDownloadSelection: {
                let selected = selectedItems(from: selectedPaths)
                guard !selected.isEmpty else { return }
                let downloadable = selected.filter { canDownloadForItem($0) }
                guard !downloadable.isEmpty else { return }
                onRequestDownloadSelection(downloadable)
            },
            onRequestGetInfo: { item in
                guard canGetInfoForItem(item) else { return }
                onRequestGetInfo(item)
            },
            onRequestSyncNow: { item in
                guard item.type == FileType.sync else { return }
                onRequestSyncNow(item)
            },
            onRequestActivateSync: { item in
                guard item.type == FileType.sync else { return }
                onRequestActivateSync(item)
            },
            onRequestDeactivateSync: { item in
                guard item.type == FileType.sync else { return }
                onRequestDeactivateSync(item)
            },
            syncPairStatusForPath: { path in
                return syncPairStatusForItem(FileItem("", path: path, type: .sync))
            },
            syncPairExistsForPath: { path in
                syncPairExistsForItem(FileItem("", path: path, type: .sync))
            },
            syncPairStatusVersion: syncPairStatusVersion,
            canSetFileType: canSetFileType,
            canGetInfoForItem: canGetInfoForItem,
            canDownloadForItem: canDownloadForItem,
            canDeleteForItem: canDeleteForItem,
            canUploadToDirectory: canUploadToDirectory,
            canCreateFolderInDirectory: canCreateFolderInDirectory,
            canDropRemoteItem: canDropRemoteItem,
            canSetLabel: canSetLabel,
            onRequestSetLabel: onRequestSetLabel,
            savedScrollOffset: filesViewModel.treeScrollOffset,
            onScrollOffsetChange: { filesViewModel.treeScrollOffset = $0 }
        )
        .background(colorScheme == .light ? Color.white : Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !filesViewModel.isSearchMode {
                Task { await filesViewModel.loadTreeRoot() }
            }
            selectedPaths = Set([filesViewModel.treeSelectionPath].compactMap { $0 })
        }
        .onChange(of: filesViewModel.treeSelectionPath) { _, newValue in
            if selectedPaths.count <= 1 {
                selectedPaths = Set([newValue].compactMap { $0 })
            }
        }
        #else
        EmptyView()
        #endif
    }

    private func selectedItems(from paths: Set<String>) -> [FileItem] {
        let byPath = Dictionary(uniqueKeysWithValues: filesViewModel.visibleTreeNodes().map { ($0.item.path, $0.item) })
        return paths.compactMap { byPath[$0] }
    }

    private func contextMenuTargetDirectory() -> FileItem {
        if let selected = filesViewModel.selectedTreeItem() {
            if selected.type.isDirectoryLike {
                return selected
            }

            let parentPath = selected.path.stringByDeletingLastPathComponent
            return FileItem(parentPath.lastPathComponent, path: parentPath, type: .directory)
        }

        let root = filesViewModel.treeRootPath
        let rootName = root == "/" ? "/" : (root as NSString).lastPathComponent
        return FileItem(rootName, path: root, type: .directory)
    }
}
