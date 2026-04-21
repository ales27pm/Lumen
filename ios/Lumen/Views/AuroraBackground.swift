import SwiftUI

struct AppBackground: View {
    var body: some View {
        Color(red: 0.055, green: 0.055, blue: 0.06)
            .ignoresSafeArea()
    }
}

struct AuroraBackground: View {
    var body: some View {
        AppBackground()
    }
}

enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let surface = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let surfaceHigh = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.14)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.38)
    static let accent = Color(red: 0.45, green: 0.62, blue: 1.0)
}
