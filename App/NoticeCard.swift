import DesignSystem
import SwiftUI

/// A small card near the menu bar, for something worth saying once.
struct NoticeCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let primary: LocalizedStringKey
    let secondary: LocalizedStringKey
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(Palette.verdigris)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Button(action: onPrimary) {
                    Text(primary).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionStyle())
                Button(action: onSecondary) {
                    Text(secondary).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 300)
        .tint(Palette.verdigris)
    }
}
