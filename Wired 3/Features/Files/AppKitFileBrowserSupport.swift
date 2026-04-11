#if os(macOS)
import AppKit

enum SyncContextMenuItemTag {
    static let status  = 9_101
    static let toggle  = 9_102
    static let syncNow = 9_103
}

/// Tag base for label submenu items: base + FileLabelValue.rawValue (0–7)
enum LabelContextMenuItemTag {
    static let submenu = 9_200
    static let itemBase = 9_210  // 9_210 … 9_217
}

// MARK: - Label submenu factory

/// Builds a "Label" NSMenuItem with a submenu containing one entry per FileLabelValue.
/// Each entry carries a colored dot NSImage (drawn directly — SF symbols in menus are
/// always rendered as monochrome templates on macOS).
/// `target` must implement `contextSetLabel(_ sender: NSMenuItem)`.
func makeLabelSubmenuItem(target: AnyObject) -> NSMenuItem {
    let submenu = NSMenu(title: "Label")
    for label in FileLabelValue.allCases {
        let item = NSMenuItem(
            title: label.title,
            action: #selector(FileLabelMenuTarget.contextSetLabel(_:)),
            keyEquivalent: ""
        )
        item.tag = LabelContextMenuItemTag.itemBase + Int(label.rawValue)
        item.image = label.contextDotImage
        item.target = target
        submenu.addItem(item)
    }

    let parent = NSMenuItem(title: "Label", action: nil, keyEquivalent: "")
    parent.tag = LabelContextMenuItemTag.submenu
    parent.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
    parent.submenu = submenu
    return parent
}

/// Marker protocol so the selector compiles on both Coordinator types.
@objc protocol FileLabelMenuTarget {
    func contextSetLabel(_ sender: NSMenuItem)
}

// MARK: - Colored dot image for label menu items

private extension FileLabelValue {
    /// A 12×12 NSImage with the label color drawn directly.
    /// Unlike SF symbols, bitmap NSImages in menu items preserve their colors.
    var contextDotImage: NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            if self == .none {
                NSColor.tertiaryLabelColor.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                path.lineWidth = 1.5
                path.stroke()
            } else {
                self.swiftUIColor.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            }
            return true
        }
    }

    var swiftUIColor: NSColor {
        switch self {
        case .none:   return .secondaryLabelColor
        case .red:    return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green:  return .systemGreen
        case .blue:   return .systemBlue
        case .purple: return .systemPurple
        case .gray:   return .systemGray
        }
    }
}

var wiredRemotePathPasteboardType = NSPasteboard.PasteboardType("com.read-write.wired.remote-path")
#endif
