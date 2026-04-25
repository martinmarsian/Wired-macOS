//
//  OfflineUser.swift
//  Wired 3
//

import Foundation

@Observable
@MainActor
final class OfflineUser: Identifiable {
    let login: String
    var nick: String

    var id: String { login }

    init(login: String, nick: String? = nil) {
        self.login = login
        self.nick = nick ?? login
    }
}
