//
//  ServerInfoView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 07/01/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct ServerInfoView: View {
    @Environment(ConnectionRuntime.self) private var runtime

    /// True if we have a stored TOFU fingerprint for this server.
    private var serverTrustFingerprint: String? {
        guard let hostname = runtime.connectionController.configuration(for: runtime.id)?.hostname else {
            return nil
        }
        return ServerTrustStore.storedFingerprint(host: hostname, port: 4871)
    }

    var body: some View {
        Group {
            if let serverInfo = runtime.serverInfo {
                VStack(spacing: 0) {
                    Image(data: serverInfo.serverBanner)

                    VStack {
                        Text(serverInfo.serverName)
                            .font(.title)

                        Text(serverInfo.serverDescription)
                            .font(.caption)
                    }
                    .padding(.vertical, 8)

                    // SECURITY (A_009): Server identity badge
                    serverIdentityBadge
                        .padding(.bottom, 8)

                    Divider()

                    LabeledContent {
                        Text(serverInfo.applicationName)
                    } label: {
                        Text("Application Name").bold()
                    }

                    LabeledContent {
                        Text(serverInfo.serverVersion)
                    } label: {
                        Text("Server Version").bold()
                    }

                    Divider()

                    LabeledContent {
                        Text(serverInfo.osName)
                    } label: {
                        Text("OS Name").bold()
                    }

                    LabeledContent {
                        Text(serverInfo.osVersion)
                    } label: {
                        Text("OS Version").bold()
                    }

                    LabeledContent {
                        Text(serverInfo.arch)
                    } label: {
                        Text("OS Arch").bold()
                    }

                    Divider()

                    LabeledContent {
                        Text("\(serverInfo.filesCount) files")
                    } label: {
                        Text("Files").bold()
                    }

                    LabeledContent {
                        Text("\(ByteCountFormatter().string(fromByteCount: Int64(serverInfo.filesSize)))")
                    } label: {
                        Text("Size").bold()
                    }

                    LabeledContent {
                        Text(serverInfo.startTime, style: .timer)
                    } label: {
                        Text("Uptime").bold()
                    }
                }
                .frame(maxWidth: 400)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading server information…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .task(id: "\(runtime.status)-\(runtime.selectedTab)") {
            await refreshServerInfoIfNeeded()
        }
    }

    // MARK: - Identity badge

    @ViewBuilder
    private var serverIdentityBadge: some View {
        if let fingerprint = serverTrustFingerprint {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verified Identity")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                    Text(fingerprint)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.green.opacity(0.30), lineWidth: 1)
            )
        } else {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text("Identity not verified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Data loading

    @MainActor
    private func refreshServerInfoIfNeeded() async {
        guard runtime.status == .connected else { return }
        guard runtime.selectedTab == .infos else { return }
        guard runtime.serverInfo == nil else { return }

        if let serverInfo = runtime.connection?.serverInfo {
            runtime.serverInfo = serverInfo
            return
        }

        // Slow or remote servers may expose serverInfo slightly later than first render.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            guard runtime.status == .connected, runtime.selectedTab == .infos else { return }
            if runtime.serverInfo != nil { return }
            if let serverInfo = runtime.connection?.serverInfo {
                runtime.serverInfo = serverInfo
                return
            }
        }
    }
}
