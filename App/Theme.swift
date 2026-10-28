import SwiftUI

/// Neutral palette; color only where it carries meaning.
enum Theme {
    /// Warnings (refused live view, slow cable, low battery).
    static let warning = Color(red: 0.85, green: 0.62, blue: 0.24)
    /// Reserved for "output is live" (Milestone 4).
    static let live = Color(red: 0.86, green: 0.24, blue: 0.22)
    static let panelWidth: CGFloat = 288
    static let statusBarHeight: CGFloat = 28
}

/// Small uppercase section heading used in the side panel.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
