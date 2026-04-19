//
//  ThreadSortMenuView.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 09/04/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct ThreadSortMenuView: View {
    @Binding var criterion: ThreadSortCriterion
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            ForEach(ThreadSortCriterion.allCases) { value in
                Toggle(
                    value.label,
                    isOn: Binding(
                        get: { criterion == value },
                        set: { isSelected in
                            if isSelected {
                                criterion = value
                            }
                        }
                    )
                )
            }
            Divider()
            Toggle(
                "Ascending",
                isOn: Binding(
                    get: { ascending },
                    set: { isSelected in
                        if isSelected {
                            ascending = true
                        }
                    }
                )
            )
            Toggle(
                "Descending",
                isOn: Binding(
                    get: { !ascending },
                    set: { isSelected in
                        if isSelected {
                            ascending = false
                        }
                    }
                )
            )
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .frame(maxWidth: 30)
        .help("Sort threads")
        .menuStyle(.borderlessButton)
    }
}
