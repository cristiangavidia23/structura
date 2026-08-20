import UIKit

/// Thin wrapper so call sites read as intent ("scan saved") rather than
/// UIKit generator boilerplate repeated at every call site.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
