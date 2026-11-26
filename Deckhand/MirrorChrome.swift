import DeckhandCore
import SwiftUI

/// A progress over the device for what takes a while to the device: installing an app, copying files. One file shows
/// a spinner, several show how many are done.
struct ActivityCard: View {
    let activity: DeviceToolsViewModel.Activity

    var body: some View {
        VStack(spacing: 12) {
            if let fraction = activity.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 220)
            } else {
                ProgressView().controlSize(.large)
            }
            VStack(spacing: 3) {
                Text(activity.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if let detail = activity.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .allowsHitTesting(false)
    }
}

/// The same, small, for when the mirror is not shown.
struct ActivityPill: View {
    let activity: DeviceToolsViewModel.Activity?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let title = activity?.title { Text(title).font(.system(size: 11)).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }
}

/// A key of the strip under the mirror. Big enough to hit, and lit for a moment after a click, so a quick press is seen.
struct BarKey: View {
    static let symbolSize: CGFloat = 17
    static let width: CGFloat = 36
    static let height: CGFloat = 32

    let symbol: String
    let help: String
    let action: () -> Void
    @State private var lit = false

    var body: some View {
        Button {
            action()
            lit = true
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.25)) { lit = false }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: Self.symbolSize, weight: .medium))
                .frame(width: Self.width, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(BarKeyStyle(lit: lit))
        .help(help)
    }
}

private struct BarKeyStyle: ButtonStyle {
    let lit: Bool

    func makeBody(configuration: Configuration) -> some View {
        let active = configuration.isPressed || lit
        configuration.label
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.24 : lit ? 0.14 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
