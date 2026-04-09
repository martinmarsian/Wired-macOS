//
//  String+.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import Swift

internal extension String {
    /// Searchable terms built from Unicode scalar names (e.g. "👍" → "thumbs up sign").
    /// Multi-codepoint emoji join all base scalar names, variation selectors are skipped.
    var emojiSearchTerms: String {
        unicodeScalars
            .compactMap { $0.properties.name }   // variation selectors have no name → dropped
            .joined(separator: " ")
            .lowercased()
    }
}
