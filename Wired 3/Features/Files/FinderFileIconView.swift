import SwiftUI

extension View {
    public func sizeString(for item: FileItem) -> String {
        if item.type.isDirectoryLike {
            return "-"
        }
        let total = Int64(item.dataSize + item.rsrcSize)
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

struct FinderFileIconView: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        #if os(macOS)
        Image(nsImage: iconImage())
            .resizable()
            .frame(width: size, height: size)
        #else
        Image(systemName: item.type == .file ? "document" : "folder")
            .font(.system(size: size * 0.7))
        #endif
    }

    #if os(macOS)
    private func iconImage() -> NSImage {
        remoteItemIconImage(for: item, size: size)
    }
    #endif
}
