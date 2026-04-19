//
//  MarkdownComposer 2.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

#if os(macOS)

// MARK: - ResizableSheet

struct ResizableSheet: NSViewRepresentable {
    var minWidth: CGFloat
    var minHeight: CGFloat
    var sizeKey: String

    func makeCoordinator() -> Coordinator {
        Coordinator(sizeKey: sizeKey, minWidth: minWidth, minHeight: minHeight)
    }

    func makeNSView(context: Context) -> SheetProbeView {
        let probe = SheetProbeView()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateNSView(_ nsView: SheetProbeView, context: Context) {}

    // MARK: - Probe view

    /// Zero-size NSView subclass that configures the sheet window as soon as it
    /// enters the view hierarchy — before the first draw, avoiding any visual jump.
    final class SheetProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let coordinator, !coordinator.isConfigured else { return }
            coordinator.configure(window)
        }
    }

    // MARK: - Coordinator

    final class Coordinator {
        private let sizeKey: String
        private let minWidth: CGFloat
        private let minHeight: CGFloat

        private(set) var isConfigured = false
        /// The size the user last set (or the restored/default size). We lock
        /// the window to this size so SwiftUI content changes don't resize it.
        private var targetSize: CGSize = .zero
        private var observers: [NSObjectProtocol] = []

        init(sizeKey: String, minWidth: CGFloat, minHeight: CGFloat) {
            self.sizeKey = sizeKey
            self.minWidth = minWidth
            self.minHeight = minHeight
        }

        func configure(_ window: NSWindow) {
            isConfigured = true

            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: minWidth, height: minHeight)

            let saved = loadSize()
            targetSize = CGSize(
                width: max(saved?.width ?? minWidth, minWidth),
                height: max(saved?.height ?? minHeight, minHeight)
            )
            window.setContentSize(NSSize(width: targetSize.width, height: targetSize.height))

            // User finished a manual resize → persist new size
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                let sz = window.contentRect(forFrameRect: window.frame).size
                self.targetSize = sz
                self.saveSize(sz)
            })

            // SwiftUI-driven resize (content change) → restore targetSize.
            // queue: nil = fires synchronously on the posting thread (main),
            // before the next draw cycle → no visible flash.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: nil
            ) { [weak self, weak window] _ in
                guard let self, let window, !window.inLiveResize else { return }
                let current = window.contentRect(forFrameRect: window.frame).size
                let target = self.targetSize
                if abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 {
                    window.setContentSize(NSSize(width: target.width, height: target.height))
                }
            })
        }

        private func loadSize() -> CGSize? {
            guard let dict = UserDefaults.standard.dictionary(forKey: sizeKey),
                  let w = dict["w"] as? Double,
                  let h = dict["h"] as? Double else { return nil }
            return CGSize(width: w, height: h)
        }

        private func saveSize(_ size: CGSize) {
            UserDefaults.standard.set(
                ["w": Double(size.width), "h": Double(size.height)],
                forKey: sizeKey
            )
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

struct MarkdownComposer: View {
    @Binding var text: String
    @Binding var attachments: [ComposerAttachmentItem]
    var minHeight: CGFloat = 180
    var autoFocus: Bool = false
    var bordered: Bool = false
    var onOptionEnter: (() -> Void)?
    var onAttachmentError: ((Error) -> Void)?

    @State private var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @State private var showPreview = false
    @State private var isAttachmentDropTargeted = false

    init(
        text: Binding<String>,
        attachments: Binding<[ComposerAttachmentItem]> = .constant([]),
        minHeight: CGFloat = 180,
        autoFocus: Bool = false,
        bordered: Bool = false,
        onOptionEnter: (() -> Void)? = nil,
        onAttachmentError: ((Error) -> Void)? = nil
    ) {
        self._text = text
        self._attachments = attachments
        self.minHeight = minHeight
        self.autoFocus = autoFocus
        self.bordered = bordered
        self.onOptionEnter = onOptionEnter
        self.onAttachmentError = onAttachmentError
    }

    var body: some View {
        baseContent
            .overlay(
                Group {
                    if bordered {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(isAttachmentDropTargeted ? 0.9 : 0), lineWidth: 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(isAttachmentDropTargeted ? 0.08 : 0))
                    )
                    .padding(4)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isAttachmentDropTargeted) { providers in
                handleFileDrop(providers: providers)
            }
    }

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

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolbarButton(icon: "bold", help: "Bold") {
                wrapSelection(prefix: "**", suffix: "**", placeholder: "bold")
            }
            toolbarButton(icon: "italic", help: "Italic") {
                wrapSelection(prefix: "*", suffix: "*", placeholder: "italic")
            }
            toolbarButton(icon: "chevron.left.forwardslash.chevron.right", help: "Inline Code") {
                wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
            }
            Divider().frame(height: 14).padding(.horizontal, 3)
            toolbarButton(icon: "link", help: "Link") { insertLink() }
            toolbarButton(icon: "photo", help: "Image") { insertImage() }
            toolbarButton(icon: "paperclip", help: "Attach file") { chooseFiles() }
            Divider().frame(height: 14).padding(.horizontal, 3)
            toolbarButton(icon: "text.quote", help: "Quote") { prefixLines(with: "> ") }
            toolbarButton(icon: "list.bullet", help: "List") { prefixLines(with: "- ") }
            Spacer(minLength: 0)
            Divider().frame(height: 14).padding(.horizontal, 4)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showPreview.toggle() }
            } label: {
                Image(systemName: showPreview ? "pencil" : "eye")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(showPreview ? "Edit" : "Preview")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var previewPane: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to preview")
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
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            ComposerAttachmentChipView(attachment: attachment) {
                                removeAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }

                Divider()
            }

            MarkdownTextView(
                text: $text,
                selectedRange: $selectedRange,
                autoFocus: autoFocus,
                onOptionEnter: onOptionEnter
            )
            .frame(minHeight: minHeight, maxHeight: .infinity)
        }
    }

    private func toolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(showPreview)
    }

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
            selectedRange = NSRange(location: range.location + (prefix as NSString).length, length: (selected as NSString).length)
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

    private func insertAttachmentReferences(_ references: [String]) {
        guard !references.isEmpty else { return }
        let replacement = references.joined(separator: "\n")
        let ns = text as NSString
        let range = clampedRange(in: text)
        text = ns.replacingCharacters(in: range, with: replacement)
        let caret = range.location + (replacement as NSString).length
        selectedRange = NSRange(location: caret, length: 0)
    }

    private func removeAttachment(_ attachment: ComposerAttachmentItem) {
        attachments.removeAll { $0.id == attachment.id }
        text = text.replacingOccurrences(of: attachment.markdownReference, with: "")
            .replacingOccurrences(of: attachment.referenceURLString, with: "")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    private func addFiles(_ urls: [URL]) {
        do {
            var updated = attachments
            var insertedReferences: [String] = []

            for url in urls {
                let draft = try ChatDraftAttachment(fileURL: url)
                let item = ComposerAttachmentItem.local(draft)
                let alreadyPresent = updated.contains { existing in
                    switch (existing, item) {
                    case (.local(let lhs), .local(let rhs)):
                        return lhs.fileURL == rhs.fileURL
                    case (.remote(let lhs), .remote(let rhs)):
                        return lhs.id == rhs.id
                    default:
                        return false
                    }
                }

                guard !alreadyPresent else { continue }
                updated.append(item)
                insertedReferences.append(item.markdownReference)
            }

            try ComposerAttachmentItem.validateCollection(updated)
            attachments = updated
            insertAttachmentReferences(insertedReferences)
        } catch {
            onAttachmentError?(error)
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let error {
                    DispatchQueue.main.async {
                        onAttachmentError?(error)
                    }
                    return
                }

                guard let data,
                      let fileURL = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                DispatchQueue.main.async {
                    addFiles([fileURL])
                }
            }
        }

        return true
    }
}

private struct ComposerAttachmentChipView: View {
    let attachment: ComposerAttachmentItem
    let onRemove: () -> Void

    private var iconName: String {
        attachment.isImage ? "photo" : "doc"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            (
                Text(attachment.fileName)
                    .font(.subheadline.weight(.medium))
                +
                Text("  \(attachment.fileSizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
            .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var autoFocus: Bool = false
    var onOptionEnter: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedRange: $selectedRange, onOptionEnter: onOptionEnter)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = FocusTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.insertionPointColor = .controlTextColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        textView.onOptionEnter = { [weak coordinator = context.coordinator] in
            coordinator?.onOptionEnter?()
        }
        textView.delegate = context.coordinator
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.didAutoFocus = false

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

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

        if autoFocus, context.coordinator.didAutoFocus == false {
            context.coordinator.didAutoFocus = true
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var selectedRange: NSRange
        var onOptionEnter: (() -> Void)?
        weak var textView: NSTextView?
        var isProgrammaticChange = false
        var didAutoFocus = false

        init(text: Binding<String>, selectedRange: Binding<NSRange>, onOptionEnter: (() -> Void)?) {
            _text = text
            _selectedRange = selectedRange
            self.onOptionEnter = onOptionEnter
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

private final class FocusTextView: NSTextView {
    var onOptionEnter: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isOptionEnter = flags == .option && (event.keyCode == 36 || event.keyCode == 76)
        if isOptionEnter {
            onOptionEnter?()
            return
        }

        super.keyDown(with: event)
    }
}
#else
struct MarkdownComposer: View {
    @Binding var text: String
    @Binding var attachments: [ComposerAttachmentItem]
    var minHeight: CGFloat = 180
    var autoFocus: Bool = false
    var onOptionEnter: (() -> Void)?
    var onAttachmentError: ((Error) -> Void)?

    init(
        text: Binding<String>,
        attachments: Binding<[ComposerAttachmentItem]> = .constant([]),
        minHeight: CGFloat = 180,
        autoFocus: Bool = false,
        onOptionEnter: (() -> Void)? = nil,
        onAttachmentError: ((Error) -> Void)? = nil
    ) {
        self._text = text
        self._attachments = attachments
        self.minHeight = minHeight
        self.autoFocus = autoFocus
        self.onOptionEnter = onOptionEnter
        self.onAttachmentError = onAttachmentError
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                button("B", help: "Gras") { append("**bold**") }
                button("I", help: "Italique") { append("*italic*") }
                button("Code", help: "Code inline") { append("`code`") }
                button("Link", help: "Lien") { append("[label](https://)") }
                button("Img", help: "Image") { append("![alt](https://)") }
                button("Attach", help: "Attachment") {}
                button("Quote", help: "Citation") { append("\n> ") }
                button("List", help: "Liste") { append("\n- ") }
                Spacer(minLength: 0)
            }

            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                        .allowsHitTesting(false)
                )
        }
        .padding(8)
    }

    private func button(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
    }

    private func append(_ snippet: String) {
        if text.isEmpty {
            text = snippet
        } else {
            text += snippet
        }
    }
}
#endif
