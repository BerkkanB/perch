import SwiftUI

private typealias Layout = NotchModel.List

/// The menu bar panel: the same black list as the open notch, plus the one-time permission row
/// when it's needed and Settings and Quit at the bottom.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var app
    @State private var accessError: String?

    var body: some View {
        let primary = app.primary

        VStack(alignment: .leading, spacing: 0) {
            StatsLine()
                .frame(height: Layout.statsHeight)
                .padding(.horizontal, Layout.rowInset)
                .padding(.top, 12)
                .padding(.bottom, Layout.statsGap)

            PrimaryModuleRow(module: primary)

            if let notice = primary.notice {
                NoticeRow(notice: notice)
                    .padding(.horizontal, Layout.rowInset)
                    .padding(.leading, 36)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }

            VStack(spacing: Layout.rowSpacing) {
                ForEach(app.secondary, id: \.id) { module in
                    CompactModuleRow(module: module)
                        .frame(height: Layout.rowHeight)
                }

                if app.access.needsAttention {
                    ActionRow(
                        symbol: "key.fill",
                        title: app.access.isInstalled ? "Update password-free switching" : "Allow password-free switching",
                        detail: "one time",
                        tint: Palette.stayAwake,
                        action: allowPasswordFree
                    )
                    .help("Lets Perch run only pmset -a disablesleep 0 and 1 without asking for your password.")
                }
            }
            .padding(.top, Layout.rowSpacing)

            if let accessError {
                Text(accessError)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, Layout.rowInset)
                    .padding(.leading, 36)
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, Layout.rowInset)
                .padding(.vertical, 6)

            HStack(spacing: 0) {
                ActionRow(symbol: "gearshape.fill", title: "Settings", detail: "⌘,", action: app.openSettings)
                ActionRow(symbol: "power", title: "Quit", detail: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, Layout.panelInset)
        .padding(.bottom, 8)
        .frame(width: 440)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: primary.notice)
        .animation(.easeInOut(duration: 0.2), value: app.access.needsAttention)
    }

    private func allowPasswordFree() {
        do {
            try app.access.installRule()
            accessError = nil
        } catch PrivilegeError.cancelled {
            accessError = nil
        } catch {
            accessError = error.localizedDescription
        }
    }
}
