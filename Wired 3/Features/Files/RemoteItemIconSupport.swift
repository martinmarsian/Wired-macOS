import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

private enum RemoteFolderIconKind: String {
    case directory
    case uploads
    case dropbox
    case sync
}

private final class RemoteFolderIconCache {
    static let shared = RemoteFolderIconCache()
    private var cache: [String: NSImage] = [:]

    private init() {}

    func icon(for kind: RemoteFolderIconKind, label: FileLabelValue, size: CGFloat) -> NSImage {
        let normalizedSize = max(1, Int(round(size)))
        let key = "\(kind.rawValue)-\(label.rawValue)-\(normalizedSize)"
        if let cached = cache[key] {
            return cached
        }

        let icon = makeIcon(for: kind, label: label, size: CGFloat(normalizedSize))
        cache[key] = icon
        return icon
    }

    private func makeIcon(for kind: RemoteFolderIconKind, label: FileLabelValue, size: CGFloat) -> NSImage {
        let frame = NSSize(width: size, height: size)
        let base = NSWorkspace.shared.icon(for: .folder)
        base.size = frame

        let folderBase = tint(baseFolderIcon: base, with: label)

        guard kind != .directory else {
            return folderBase
        }

        let badgeName: String = {
            switch kind {
            case .uploads: return "UploadsBadge"
            case .dropbox: return "DropBoxBadge"
            case .sync: return "SyncBadge"
            case .directory: return ""
            }
        }()
        guard let badgeImage = loadBadgeImage(named: badgeName)?.copy() as? NSImage else {
            return folderBase
        }
        let badgeScale: CGFloat = 1.60
        let badgeSize = NSSize(width: frame.width * badgeScale, height: frame.height * badgeScale)
        let badgeRect = NSRect(
            x: frame.width - badgeSize.width,
            y: 0,
            width: badgeSize.width,
            height: badgeSize.height
        )
        badgeImage.size = badgeRect.size

        let composed = NSImage(size: frame)
        composed.lockFocus()
        folderBase.draw(in: NSRect(origin: .zero, size: frame))
        badgeImage.draw(in: badgeRect)
        composed.unlockFocus()
        return composed
    }

    /// Tints the Finder native folder icon with the label color.
    /// Pipeline:
    ///   1. Desaturate to neutral gray (removes blue bias from the Finder icon).
    ///   2. Paint the label color at high opacity via .sourceAtop (respects icon alpha,
    ///      no background bleed). The residual ~20 % gray provides the 3D depth.
    ///   3. Restore highlights by overlaying the original icon at low opacity with
    ///      .luminosity, so the bright specular areas stay crisp.
    private func tint(baseFolderIcon: NSImage, with label: FileLabelValue) -> NSImage {
        guard label != .none else { return baseFolderIcon }

        let size = baseFolderIcon.size
        let rect = NSRect(origin: .zero, size: size)

        // Step 1 — desaturate: draw a gray mask shaped to the icon via .destinationIn,
        // then composite it onto the original with .saturation (S→0, keeps H+L).
        let grayMask = NSImage(size: size)
        grayMask.lockFocus()
        NSColor(calibratedWhite: 0.5, alpha: 1.0).setFill()
        rect.fill()
        baseFolderIcon.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
        grayMask.unlockFocus()

        let grayIcon = NSImage(size: size)
        grayIcon.lockFocus()
        baseFolderIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        grayMask.draw(in: rect, from: .zero, operation: .saturation, fraction: 1.0)
        grayIcon.unlockFocus()

        guard label != .gray else { return grayIcon }

        // Step 2 — colorize: paint the vivid label color at 80 % opacity.
        // .sourceAtop clips the fill to existing pixels (no halo around the icon).
        let result = NSImage(size: size)
        result.lockFocus()
        grayIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        label.vividColor.withAlphaComponent(0.80).setFill()
        rect.fill(using: .sourceAtop)

        // Step 3 — restore highlights: the original icon at 25 % with .luminosity
        // brings back the specular white areas without re-introducing the blue cast.
        baseFolderIcon.draw(in: rect, from: .zero, operation: .luminosity, fraction: 0.25)
        result.unlockFocus()

        return result
    }

    private func loadBadgeImage(named name: String) -> NSImage? {
        if let image = NSImage(named: name) {
            return image
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

func remoteItemIconImage(for item: FileItem, size: CGFloat) -> NSImage {
    let icon: NSImage

    switch item.type {
    case .file:
        let ext = (item.name as NSString).pathExtension
        let contentType = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        icon = NSWorkspace.shared.icon(for: contentType)
    case .directory:
        icon = RemoteFolderIconCache.shared.icon(for: .directory, label: item.label, size: size)
    case .uploads:
        icon = RemoteFolderIconCache.shared.icon(for: .uploads, label: item.label, size: size)
    case .dropbox:
        icon = RemoteFolderIconCache.shared.icon(for: .dropbox, label: item.label, size: size)
    case .sync:
        icon = RemoteFolderIconCache.shared.icon(for: .sync, label: item.label, size: size)
    }

    let copy = (icon.copy() as? NSImage) ?? icon
    copy.size = NSSize(width: size, height: size)
    return copy
}

private extension FileLabelValue {
    /// Fully saturated RGB colors used for folder tinting.
    /// Using explicit values instead of NSColor.system* to avoid adaptive/dynamic
    /// colors whose actual RGB can vary with appearance and be less saturated.
    var vividColor: NSColor {
        switch self {
        case .none:  return .secondaryLabelColor
        case .red:   return NSColor(calibratedRed: 0.92, green: 0.08, blue: 0.10, alpha: 1)
        case .orange: return NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.00, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.00, alpha: 1)
        case .green:  return NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.18, alpha: 1)
        case .blue:   return NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.95, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.88, alpha: 1)
        case .gray:   return NSColor(calibratedWhite: 0.50, alpha: 1)
        }
    }
}
#endif
