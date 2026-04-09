import SwiftUI

struct FilePreviewColumn: View {
    let selectedItem: FileItem?
    @Environment(\.colorScheme) private var colorScheme

    private var platformBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = selectedItem {
                HStack {
                    Spacer()
                    VStack(alignment: .center, spacing: 10) {
                        FinderFileIconView(item: item, size: 128)

                        Text(item.name.isEmpty ? item.path : item.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                Divider()

                Group {
                    infoRow("Type", item.type.description)
                    infoRow("Size", sizeString(for: item))
                    infoRow("Created", dateString(item.creationDate))
                    infoRow("Modified", dateString(item.modificationDate))
                    infoRow("Contains", containsString(for: item))
                }
            } else {
                Text("Select a file or folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(colorScheme == .light ? Color.white : platformBackgroundColor)
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
    }

    private func containsString(for item: FileItem) -> String {
        if item.type.isDirectoryLike {
            guard item.hasDirectoryCount else { return "-" }
            return item.directoryCount == 1 ? "1 item" : "\(item.directoryCount) items"
        }
        return "-"
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return "-" }
        return dateFormatter.string(from: date)
    }
}
