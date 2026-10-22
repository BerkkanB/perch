import AppKit
import SwiftUI

/// A standard macOS settings window: toolbar tabs, each a grouped form.
@MainActor
final class SettingsWindowController {
    private let app: AppModel
    private(set) var window: NSWindow?
    private var tabs: NSTabViewController?

    init(app: AppModel) {
        self.app = app
    }

    func show(tab: SettingsTab? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabsController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]

        for tab in SettingsTab.allCases {
            let page = NSHostingController(rootView: AnyView(tab.view.environment(app)))
            page.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.title = SettingsTab.general.title
        window.center()
        self.tabs = tabs
        return window
    }
}

/// Keeps the window title in step with the selected tab, as in System Settings-style windows.
final class SettingsTabsController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}
