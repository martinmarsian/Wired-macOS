import Foundation
import Darwin
struct LocalEntry {
    let relativePath: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
}

struct RemoteEntry {
    let relativePath: String
    let absolutePath: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
}

func syncPathContainsHiddenPathComponent(_ relativePath: String) -> Bool {
    for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
        if component.hasPrefix(".") {
            return true
        }
    }
    return false
}

func syncPathIsConflictArtifact(_ relativePath: String) -> Bool {
    let fileName = (relativePath as NSString).lastPathComponent.lowercased()
    return fileName.contains(".conflict.")
}

func syncPathIsTransientTransferArtifact(_ relativePath: String) -> Bool {
    let fileName = (relativePath as NSString).lastPathComponent.lowercased()
    return fileName.hasSuffix(".wiredtransfer") || fileName.hasSuffix(".wiredsync.part")
}

func syncPathIsExcluded(_ relativePath: String, excludePatterns: [String]) -> Bool {
    guard !excludePatterns.isEmpty else { return false }
    let fileName = (relativePath as NSString).lastPathComponent
    for pattern in excludePatterns {
        let pat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty, !pat.hasPrefix("#") else { continue }
        if pat.contains("/") {
            if fnmatch(pat, relativePath, FNM_PATHNAME) == 0 { return true }
        } else {
            if fnmatch(pat, fileName, 0) == 0 { return true }
        }
    }
    return false
}

func shouldIgnoreSyncRelativePath(_ relativePath: String, excludePatterns: [String]) -> Bool {
    syncPathContainsHiddenPathComponent(relativePath)
        || syncPathIsConflictArtifact(relativePath)
        || syncPathIsTransientTransferArtifact(relativePath)
        || syncPathIsExcluded(relativePath, excludePatterns: excludePatterns)
}
