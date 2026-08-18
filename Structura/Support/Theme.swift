import SwiftUI
import UIKit

enum Theme {
    static let paper = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)
            : UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1)
    })

    static let ink = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
            : UIColor(red: 0.14, green: 0.12, blue: 0.10, alpha: 1)
    })

    static let cardBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1)
            : UIColor.white
    })

    static let accent = Color(red: 0.72, green: 0.35, blue: 0.20)
}
