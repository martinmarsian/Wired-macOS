//
//  TrackerBookmark.swift
//  Wired 3
//
//  Created by Codex on 03/04/2026.
//

import Foundation
import SwiftData
import WiredSwift

@Model
final class TrackerBookmark {
    @Attribute(.unique) var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var login: String
    var lastRefreshAt: Date?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = Wired.wiredPort,
        login: String = "guest",
        lastRefreshAt: Date? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.login = login
        self.lastRefreshAt = lastRefreshAt
        self.sortOrder = sortOrder
    }

    var displayAddress: String {
        port == Wired.wiredPort ? hostname : "\(hostname):\(port)"
    }

    var credentialKey: String {
        "tracker:\(login)@\(hostname):\(port)"
    }

    var snapshot: TrackerBookmarkSnapshot {
        TrackerBookmarkSnapshot(
            id: id,
            name: name,
            hostname: hostname,
            port: port,
            login: login,
            lastRefreshAt: lastRefreshAt,
            credentialKey: credentialKey
        )
    }
}

struct TrackerBookmarkSnapshot: Hashable, Sendable {
    let id: UUID
    let name: String
    let hostname: String
    let port: Int
    let login: String
    let lastRefreshAt: Date?
    let credentialKey: String

    var displayAddress: String {
        port == Wired.wiredPort ? hostname : "\(hostname):\(port)"
    }

    func makeURL(password: String) -> Url {
        var components = URLComponents()
        components.scheme = Wired.wiredScheme
        components.host = hostname
        components.port = port == Wired.wiredPort ? nil : port

        let trimmedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLogin.isEmpty {
            components.user = trimmedLogin
        }

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPassword.isEmpty {
            components.password = trimmedPassword
        }

        return Url(withString: components.string ?? "wired://\(displayAddress)")
    }
}
