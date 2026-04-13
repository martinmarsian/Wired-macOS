//
//  FilesBreadcrumbView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 13/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct FilesBreadcrumb: View {
    private enum ScrollAnchorID {
        static let trailing = "breadcrumb-trailing-anchor"
    }

    struct Segment: Identifiable {
        let path: String
        let title: String
        let item: FileItem

        var id: String { path }
    }

    let currentPath: String
    let itemForPath: (String) -> FileItem?
    let onNavigate: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredPath: String?

    private var segments: [Segment] {
        let normalized = normalizedRemotePath(currentPath)
        if normalized == "/" {
            return [segment(for: "/")]
        }

        var paths = ["/"]
        var current = ""
        for component in normalized.split(separator: "/").map(String.init) where !component.isEmpty {
            current += "/" + component
            paths.append(current)
        }

        return paths.map(segment(for:))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        breadcrumbButton(for: segment)

                        if index < segments.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(ScrollAnchorID.trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .onAppear {
                scrollToTrailing(proxy, animated: false)
            }
            .onChange(of: currentPath) { _, _ in
                scrollToTrailing(proxy)
            }
            .onChange(of: hoveredPath) { _, _ in
                scrollToTrailing(proxy)
            }
        }
        .background(backgroundColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backgroundColor: Color {
        colorScheme == .light ? Color(nsColor: .controlBackgroundColor) : .clear
    }

    private func breadcrumbButton(for segment: Segment) -> some View {
        Button {
            onNavigate(segment.path)
        } label: {
            HStack(spacing: 6) {
                FinderFileIconView(item: segment.item, size: 14)
                HoverRevealText(
                    text: segment.title,
                    maxCollapsedWidth: 180,
                    isHovered: hoveredPath == segment.path
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(capsuleBackground(for: segment.path))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .zIndex(hoveredPath == segment.path ? 1 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                hoveredPath = hovering ? segment.path : (hoveredPath == segment.path ? nil : hoveredPath)
            }
        }
    }

    private func capsuleBackground(for path: String) -> some ShapeStyle {
        normalizedRemotePath(path) == normalizedRemotePath(currentPath)
            ? AnyShapeStyle(.quaternary)
            : AnyShapeStyle(.clear)
    }

    private func segment(for path: String) -> Segment {
        let normalized = normalizedRemotePath(path)
        let item = itemForPath(normalized) ?? fallbackItem(for: normalized)
        let title = normalized == "/" ? "/" : item.name
        return Segment(path: normalized, title: title, item: item)
    }

    private func fallbackItem(for path: String) -> FileItem {
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        return FileItem(name, path: path, type: .directory)
    }

    private func normalizedRemotePath(_ path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "/" }
        return "/" + trimmed
    }

    private func scrollToTrailing(_ proxy: ScrollViewProxy, animated: Bool = true) {
        Task { @MainActor in
            await Task.yield()
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(ScrollAnchorID.trailing, anchor: .trailing)
                }
            } else {
                proxy.scrollTo(ScrollAnchorID.trailing, anchor: .trailing)
            }
        }
    }
}

private struct HoverRevealText: View {
    let text: String
    let maxCollapsedWidth: CGFloat
    let isHovered: Bool

    private var naturalWidth: CGFloat {
        measuredTextWidth(text) + 2
    }

    private var collapsedWidth: CGFloat {
        min(naturalWidth, maxCollapsedWidth)
    }

    private var shouldExpand: Bool {
        naturalWidth > maxCollapsedWidth + 1
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: displayedWidth, alignment: .leading)
            .animation(.easeOut(duration: 0.18), value: displayedWidth)
    }

    private var displayedWidth: CGFloat {
        if shouldExpand && isHovered {
            return naturalWidth
        }
        return collapsedWidth
    }

    private func measuredTextWidth(_ text: String) -> CGFloat {
#if os(macOS)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        return ceil((text as NSString).size(withAttributes: attributes).width)
#else
        return maxCollapsedWidth
#endif
    }
}
