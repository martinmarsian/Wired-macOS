//
//  FilesServerInfos.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 13/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct FilesServerInfos: View {
    @Environment(ConnectionRuntime.self) private var runtime

    var body: some View {
        Text(serverSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.trailing, 10)
            .lineLimit(1)
            .textSelection(.enabled)
    }

    private var serverSummary: String {
        guard let serverInfo = runtime.serverInfo else {
            return "Loading server stats…"
        }

        let size = ByteCountFormatter.string(
            fromByteCount: Int64(serverInfo.filesSize),
            countStyle: .file
        )
        let count = fileCountString(serverInfo.filesCount)
        return "\(size) - \(count)"
    }

    private func fileCountString(_ count: UInt64) -> String {
        let formattedCount = count.formatted(.number.notation(.compactName))
        let suffix = count == 1 ? "file" : "files"
        return "\(formattedCount) \(suffix)"
    }
}
