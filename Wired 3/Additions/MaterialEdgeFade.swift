//
//  MaterialEdgeFade.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 16/03/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI

struct MaterialEdgeFade: ViewModifier {
    var top: CGFloat = 24
    var bottom: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                if top > 0 {
                    Rectangle()
                        .fill(.regularMaterial)
                        .mask {
                            LinearGradient(
                                colors: [.regularMaterialOpacity1, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .frame(height: top)
                        .allowsHitTesting(false)
                }
            }
            .background(alignment: .bottom) {
                if bottom > 0 {
                    Rectangle()
                        .fill(.regularMaterial)
                        .mask {
                            LinearGradient(
                                colors: [.clear, .regularMaterialOpacity1],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .frame(height: bottom)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension Color {
    // Alpha du masque (pas la couleur finale)
    static let regularMaterialOpacity1 = Color.white
}

extension View {
    func materialEdgeFade(top: CGFloat = 24, bottom: CGFloat = 24) -> some View {
        modifier(MaterialEdgeFade(top: top, bottom: bottom))
    }
}
