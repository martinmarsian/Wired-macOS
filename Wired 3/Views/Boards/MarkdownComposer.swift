import SwiftUI
import AppKit

// MARK: - ResizableSheet

/// Makes the enclosing sheet window resizable and sets its minimum size.
/// Usage: `.background { ResizableSheet(minWidth: 500, minHeight: 380) }`
struct ResizableSheet: NSViewRepresentable {
    var minWidth: CGFloat
    var minHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: minWidth, height: minHeight)
            let current = window.frame.size
            if current.width < minWidth || current.height < minHeight {
                window.setContentSize(NSSize(
                    width: max(current.width, minWidth),
                    height: max(current.height, minHeight)
                ))
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - MarkdownComposer

struct MarkdownComposer: View {
    @Binding var text: String
    var minHeight: CGFloat = 180
    var autoFocus: Bool = false
    /// Show a rounded border around the composer (for standalone/form use).
    /// Set to false when the composer is embedded edge-to-edge inside a sheet.
    var bordered: Bool = false
    var onOptionEnter: (() -> Void)? = nil

    @State private var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @State private var showPreview = false

    var body: some View {
        if bordered {
            baseContent
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        } else {
            baseContent
        }
    }

    // MARK: - Base content

    @ViewBuilder
    private var baseContent: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if showPreview {
                previewPane
            } else {
                editorPane
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton(icon: "bold", help: "Gras") {
                wrapSelection(prefix: "**", suffix: "**", placeholder: "bold")
            }
            toolbarButton(icon: "italic", help: "Italique") {
                wrapSelection(prefix: "*", suffix: "*", placeholder: "italic")
            }
            toolbarButton(icon: "chevron.left.forwardslash.chevron.right", help: "Code inline") {
                wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
            }

            toolbarSeparator

            toolbarButton(icon: "link", help: "Lien") { insertLink() }
            toolbarButton(icon: "photo", help: "Image") { insertImage() }

            toolbarSeparator

            toolbarButton(icon: "text.quote", help: "Citation") { prefixLines(with: "> ") }
            toolbarButton(icon: "list.bullet", help: "Liste") { prefixLines(with: "- ") }

            Spacer(minLength: 0)

            Divider().frame(height: 14).padding(.horizontal, 4)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showPreview.toggle() }
            } label: {
                Image(systemName: showPreview ? "pencil" : "eye")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(showPreview ? "Éditer" : "Aperçu")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var toolbarSeparator: some View {
        Divider().frame(height: 14).padding(.horizontal, 3)
    }

    // MARK: - Panes

    private var previewPane: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Rien à prévisualiser")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else if let attributed = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                } else {
                    Text(text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(minHeight: minHeight, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var editorPane: some View {
        MarkdownTextView(
            text: $text,
            selectedRange: $selectedRange,
            autoFocus: autoFocus,
            onOptionEnter: onOptionEnter
        )
        .frame(minHeight: minHeight, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: - Toolbar button

    private func toolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(showPreview)
    }

    // MARK: - Text manipulation

    private func clampedRange(in value: String) -> NSRange {
        let maxLength = (value as NSString).length
        let location = min(max(0, selectedRange.location), maxLength)
        let length = min(max(0, selectedRange.length), maxLength - location)
        return NSRange(location: location, length: length)
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let ns = text as NSString
        let range = clampedRange(in: text)
        let selected = range.length > 0 ? ns.substring(with: range) : placeholder
        let replacement = prefix + selected + suffix
        text = ns.replacingCharacters(in: range, with: replacement)

        if range.length > 0 {
            let caret = range.location + (replacement as NSString).length
            selectedRange = NSRange(location: caret, length: 0)
        } else {
            selectedRange = NSRange(
                location: range.location + (prefix as NSString).length,
                length: (selected as NSString).length
            )
        }
    }

    private func insertLink() {
        let ns = text as NSString
        let range = clampedRange(in: text)
        let selected = range.length > 0 ? ns.substring(with: range) : "label"
        let replacement = "[\(selected)](https://)"
        text = ns.replacingCharacters(in: range, with: replacement)

        let linkStart = range.location + ("[\(selected)](" as NSString).length
        selectedRange = NSRange(location: linkStart, length: ("https://" as NSString).length)
    }

    private func insertImage() {
        let ns = text as NSString
        let range = clampedRange(in: text)
        let replacement = "![alt](https://)"
        text = ns.replacingCharacters(in: range, with: replacement)

        let altStart = range.location + ("![" as NSString).length
        selectedRange = NSRange(location: altStart, length: ("alt" as NSString).length)
    }

    private func prefixLines(with prefix: String) {
        let ns = text as NSString
        let range = clampedRange(in: text)
        let lineRange = ns.lineRange(for: range)
        let chunk = ns.substring(with: lineRange)
        let lines = chunk.components(separatedBy: "\n")
        let transformed = lines.map { line -> String in
            if line.isEmpty { return prefix }
            if line.hasPrefix(prefix) { return line }
            return prefix + line
        }.joined(separator: "\n")

        text = ns.replacingCharacters(in: lineRange, with: transformed)
        selectedRange = NSRange(location: lineRange.location, length: (transformed as NSString).length)
    }
}

// MARK: - NSTextView subclass

private final class ComposerTextView: NSTextView {
    var onOptionEnter: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Option+Return (36) or Option+Enter numpad (76)
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.contains(.option)
        {
            onOptionEnter?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - NSViewRepresentable

private struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var autoFocus: Bool = false
    var onOptionEnter: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedRange: $selectedRange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ComposerTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.string = text
        textView.onOptionEnter = onOptionEnter

        scroll.documentView = textView
        context.coordinator.textView = textView

        if autoFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? ComposerTextView else { return }

        textView.onOptionEnter = onOptionEnter

        if textView.string != text {
            context.coordinator.isProgrammaticChange = true
            textView.string = text
            context.coordinator.isProgrammaticChange = false
        }

        let maxLength = (textView.string as NSString).length
        let location = min(max(0, selectedRange.location), maxLength)
        let length = min(max(0, selectedRange.length), maxLength - location)
        let clamped = NSRange(location: location, length: length)

        if !NSEqualRanges(textView.selectedRange(), clamped) {
            context.coordinator.isProgrammaticChange = true
            textView.setSelectedRange(clamped)
            context.coordinator.isProgrammaticChange = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var selectedRange: NSRange
        weak var textView: NSTextView?
        var isProgrammaticChange = false

        init(text: Binding<String>, selectedRange: Binding<NSRange>) {
            _text = text
            _selectedRange = selectedRange
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange, let textView else { return }
            text = textView.string
            selectedRange = textView.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticChange, let textView else { return }
            selectedRange = textView.selectedRange()
        }
    }
}
