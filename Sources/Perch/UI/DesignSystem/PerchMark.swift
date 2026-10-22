import SwiftUI

/// Perch's app icon: an orange tile with the notch at the top and a white sun under it.
/// Drawn with shapes (SF Symbols aren't allowed in app icons) and rendered to `AppIcon.icns`
/// by `scripts/make-icon.sh`.
struct PerchMark: View {
    var size: CGFloat
    /// Leaves the standard macOS icon margin around the tile.
    var iconMargin = false

    var body: some View {
        let tile = iconMargin ? size * 0.805 : size
        let corner = tile * 0.225
        let squircle = RoundedRectangle(cornerRadius: corner, style: .continuous)

        ZStack {
            squircle
                .fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.74, blue: 0.27), Color(red: 1.0, green: 0.47, blue: 0.0)],
                    startPoint: .top, endPoint: .bottom
                ))

            Sun(tile: tile)
                .shadow(color: Color(red: 0.6, green: 0.2, blue: 0).opacity(0.25), radius: tile * 0.02, y: tile * 0.012)
                .offset(y: tile * 0.08)

            NotchShape(topRadius: tile * 0.03, bottomRadius: tile * 0.06)
                .fill(Color(white: 0.05))
                .frame(width: tile * 0.42, height: tile * 0.13)
                .frame(maxHeight: .infinity, alignment: .top)

            squircle
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                    lineWidth: max(0.5, tile * 0.005)
                )
        }
        .frame(width: tile, height: tile)
        .clipShape(squircle)
        .shadow(color: .black.opacity(iconMargin ? 0.22 : 0), radius: size * 0.018, y: size * 0.01)
        .frame(width: size, height: size)
    }

    private struct Sun: View {
        let tile: CGFloat

        var body: some View {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: tile * 0.25, height: tile * 0.25)
                ForEach(0..<8, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: tile * 0.04, height: tile * 0.075)
                        .offset(y: -tile * 0.215)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .frame(width: tile * 0.55, height: tile * 0.55)
        }
    }
}
