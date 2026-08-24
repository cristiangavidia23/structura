import SwiftUI

/// Shared design tokens for the floating capture HUD — glassmorphism surfaces,
/// spring presets. Extends `Theme` rather than duplicating its palette.
enum HUDStyle {
    static let glass: Material = .ultraThinMaterial

    static let panelStroke = Color.white.opacity(0.15)

    static let menuSpring: Animation = .spring(response: 0.35, dampingFraction: 0.7)
    static let popSpring: Animation = .spring(response: 0.3, dampingFraction: 0.65)

    static let cornerRadius: CGFloat = 18
}
