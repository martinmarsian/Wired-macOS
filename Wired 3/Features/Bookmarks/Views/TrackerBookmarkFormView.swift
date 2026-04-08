//
//  TrackerBookmarkFormView.swift
//  Wired 3
//
//  Created by Codex on 03/04/2026.
//

import SwiftUI
import SwiftData
import KeychainSwift
import WiredSwift

struct TrackerBookmarkFormView: View {
    private enum Field: Hashable {
        case password
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var hostname: String = ""
    @State private var port: String = "\(Wired.wiredPort)"
    @State private var login: String = "guest"
    @State private var password: String = ""
    @FocusState private var focusedField: Field?

    var trackerBookmark: TrackerBookmark?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section("Connection") {
                    TextField("Hostname", text: $hostname)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif

                    TextField("Port", text: $port)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif

                    TextField("Login", text: $login)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif

                    SecureField("Password", text: $password)
                        .focused($focusedField, equals: .password)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if focusedField != nil {
                            focusedField = nil
                            DispatchQueue.main.async {
                                save()
                            }
                        } else {
                            save()
                        }
                    }
                    .disabled(hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .formStyle(.grouped)
        }
        .task(id: trackerBookmark?.id) {
            loadTrackerBookmark()
        }
    }

    private func loadTrackerBookmark() {
        guard let trackerBookmark else {
            name = ""
            hostname = ""
            port = "\(Wired.wiredPort)"
            login = "guest"
            password = ""
            return
        }

        name = trackerBookmark.name
        hostname = trackerBookmark.hostname
        port = "\(trackerBookmark.port)"
        login = trackerBookmark.login
        password = KeychainSwift().get(trackerBookmark.credentialKey) ?? ""
    }

    private func save() {
        let keychain = KeychainSwift()
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Wired.wiredPort

        guard !trimmedHostname.isEmpty else { return }

        let effectiveName = trimmedName.isEmpty ? trimmedHostname : trimmedName
        let effectiveLogin = trimmedLogin.isEmpty ? "guest" : trimmedLogin

        if let trackerBookmark {
            let previousCredentialKey = trackerBookmark.credentialKey
            trackerBookmark.name = effectiveName
            trackerBookmark.hostname = trimmedHostname
            trackerBookmark.port = parsedPort
            trackerBookmark.login = effectiveLogin

            if previousCredentialKey != trackerBookmark.credentialKey {
                keychain.delete(previousCredentialKey)
            }

            if !trimmedPassword.isEmpty {
                keychain.set(trimmedPassword, forKey: trackerBookmark.credentialKey)
            } else {
                keychain.delete(trackerBookmark.credentialKey)
            }
        } else {
            let nextSortOrder = (try? modelContext.fetch(FetchDescriptor<TrackerBookmark>()).count) ?? 0
            let bookmark = TrackerBookmark(
                name: effectiveName,
                hostname: trimmedHostname,
                port: parsedPort,
                login: effectiveLogin,
                sortOrder: nextSortOrder
            )
            modelContext.insert(bookmark)
            if !trimmedPassword.isEmpty {
                keychain.set(trimmedPassword, forKey: bookmark.credentialKey)
            }
        }

        try? modelContext.save()

        dismiss()
    }
}
