import SwiftUI
import WiredSwift

struct FilesColumnsView: View {
    let connectionID: UUID

    @ObservedObject var filesViewModel: FilesViewModel
    @EnvironmentObject private var transfers: TransferManager
    @Environment(\.colorScheme) private var colorScheme

    let onRequestCreateFolder: (FileItem) -> Void
    let onPrimarySelectionChange: (String?) -> Void
    let onSelectionItemsChange: ([FileItem]) -> Void
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
    let onUploadURLs: ([URL], FileItem) -> Void
    let onMoveRemoteItem: (_ sourcePath: String, _ destinationDirectory: FileItem) async throws -> Void

    @State private var columnWidths: [UUID: CGFloat] = [:]
    @State private var multiSelectionPathsByColumn: [UUID: Set<String>] = [:]
    @State private var previewWidth: CGFloat = 320

    private var platformBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }

    var body: some View {
        ScrollView(.horizontal) {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(filesViewModel.columns.enumerated()), id: \.element.id) { index, column in
                        columnView(column, at: index, proxy: proxy)
                        ColumnResizeHandle(width: binding(for: column.id))
                    }

                    FilePreviewColumn(selectedItem: filesViewModel.selectedItem)
                        .frame(width: previewWidth)

                    ColumnResizeHandle(width: $previewWidth)
                }
                .onAppear {
                    previewWidth = min(max(previewWidth, 240), 620)
                }
                .onChange(of: filesViewModel.columns.count) { _, _ in
                    syncColumnSelections()
                    notifySelectionItemsChanged()
                    guard let last = filesViewModel.columns.last else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.smooth) {
                            proxy.scrollTo(last.id, anchor: .trailing)
                        }
                    }
                }
            }
        }
        .background(colorScheme == .light ? Color.white : platformBackgroundColor)
        .onAppear {
            notifySelectionItemsChanged()
        }
    }

    private func columnView(_ column: FileColumn, at index: Int, proxy: ScrollViewProxy) -> some View {
        let onAppend: (FileColumn) -> Void = { appended in
            proxy.scrollTo(appended.id, anchor: .trailing)
        }
#if os(macOS)
        return AppKitFileColumnTableView(
            bookmarkID: connectionID,
            quickLookConnection: filesViewModel.activeConnection,
            transferManager: transfers,
            onDownloadTransferError: { item, message in
                filesViewModel.error = WiredError(
                    withTitle: "Download Error",
                    message: "Impossible de télécharger \"\(item.name)\":\n\(message)"
                )
            },
            column: column,
            selectedPaths: selectionPaths(for: column),
            onSelectionChange: { paths, primaryPath in
                multiSelectionPathsByColumn[column.id] = paths
                onPrimarySelectionChange(primaryPath)
                notifySelectionItemsChanged()
                guard let primaryPath,
                      let primaryItem = column.items.first(where: { $0.path == primaryPath }) else { return }

                if paths.count == 1 {
                    filesViewModel.selectColumnItem(
                        id: primaryItem.id,
                        at: index,
                        onColumnAppended: onAppend
                    )
                }
            },
            onDownloadSingleFile: { item in
                guard canDownloadForItem(item) else { return }
                onRequestDownloadSelection([item])
            },
            onUploadURLs: onUploadURLs,
            onMoveRemoteItem: onMoveRemoteItem,
            onRequestCreateFolder: onRequestCreateFolder,
            onRequestUploadInDirectory: onRequestUploadInDirectory,
            onRequestDeleteSelection: onRequestDeleteSelection,
            onRequestDownloadSelection: onRequestDownloadSelection,
            onRequestGetInfo: onRequestGetInfo,
            onRequestSyncNow: onRequestSyncNow,
            onRequestActivateSync: onRequestActivateSync,
            onRequestDeactivateSync: onRequestDeactivateSync,
            syncPairStatusForItem: syncPairStatusForItem,
            syncPairExistsForItem: syncPairExistsForItem,
            syncPairStatusVersion: syncPairStatusVersion,
            canSetFileType: canSetFileType,
            canGetInfoForItem: canGetInfoForItem,
            canDownloadForItem: canDownloadForItem,
            canDeleteForItem: canDeleteForItem,
            canUploadToDirectory: canUploadToDirectory,
            canCreateFolderInDirectory: canCreateFolderInDirectory,
            savedScrollOffset: filesViewModel.columnScrollOffsets[column.id] ?? 0,
            onScrollOffsetChange: { filesViewModel.columnScrollOffsets[column.id] = $0 }
        )
        .frame(width: width(for: column))
        .background(Color.clear)
        .id(column.id)
#else
        return List(column.items, id: \.path) { item in
            Button {
                let paths: Set<String> = [item.path]
                multiSelectionPathsByColumn[column.id] = paths
                onPrimarySelectionChange(item.path)
                notifySelectionItemsChanged()

                if item.type.isDirectoryLike {
                    filesViewModel.selectColumnItem(
                        id: item.id,
                        at: index,
                        onColumnAppended: onAppend
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    FinderFileIconView(item: item, size: 16)
                    Text(item.name)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .frame(width: width(for: column))
        .background(Color.clear)
        .id(column.id)
#endif
    }

    private func width(for column: FileColumn) -> CGFloat {
        min(max(columnWidths[column.id] ?? 240, 180), 620)
    }

    private func binding(for id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { min(max(columnWidths[id] ?? 240, 180), 620) },
            set: { columnWidths[id] = min(max($0, 180), 620) }
        )
    }

    private func syncColumnSelections() {
        var next: [UUID: Set<String>] = [:]
        for column in filesViewModel.columns {
            let existing = multiSelectionPathsByColumn[column.id] ?? []
            let validPaths = Set(column.items.map(\.path))
            let kept = existing.intersection(validPaths)
            if !kept.isEmpty {
                next[column.id] = kept
            } else if let selection = column.selection,
                      let selected = column.items.first(where: { $0.id == selection }) {
                next[column.id] = [selected.path]
            }
        }
        multiSelectionPathsByColumn = next
    }

    private func notifySelectionItemsChanged() {
        var selected: [FileItem] = []
        for column in filesViewModel.columns {
            let selectedPaths = selectionPaths(for: column)
            for item in column.items where selectedPaths.contains(item.path) {
                selected.append(item)
            }
        }
        var seen: Set<String> = []
        let unique = selected.filter { seen.insert($0.path).inserted }
        onSelectionItemsChange(unique)
    }

    private func selectionPaths(for column: FileColumn) -> Set<String> {
        if let stored = multiSelectionPathsByColumn[column.id], !stored.isEmpty {
            return stored
        }
        guard let selection = column.selection,
              let selected = column.items.first(where: { $0.id == selection }) else {
            return []
        }
        return [selected.path]
    }
}
