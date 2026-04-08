import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ColumnResizeHandle: View {
    @Binding var width: CGFloat
    @State private var dragStartWidth: CGFloat = 0
    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(isDragging ? 0.55 : (isHovering ? 0.38 : 0.18)))
            .frame(width: 1)
            .contentShape(Rectangle())
#if os(macOS)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
#endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                        }
                        if dragStartWidth == 0 {
                            dragStartWidth = width
                        }
                        width = min(max(dragStartWidth + value.translation.width, 180), 620)
                    }
                    .onEnded { _ in
                        dragStartWidth = 0
                        isDragging = false
                    }
            )
    }
}
