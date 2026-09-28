import AppKit
import SwiftUI

/// Adds a right-click context menu ("Settings", "Quit") to the menu bar icon.
///
/// The app uses SwiftUI's `MenuBarExtra` (window style) for the left-click
/// popover. `MenuBarExtra` doesn't expose right-click handling, so we locate the
/// status item's button after launch and install a local event monitor that pops
/// up an `NSMenu` on right mouse-down. Left-click continues to open the popover.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The status button isn't created until the first run-loop pass after
        // launch, so install on the next tick.
        DispatchQueue.main.async { [weak self] in
            self?.installRightClickMenu()
        }
    }

    private func installRightClickMenu() {
        guard let button = Self.statusButton() else { return }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak button] event in
            guard let button, event.window == button.window else { return event }
            Self.showContextMenu(for: button)
            return nil  // swallow the event so the popover doesn't also toggle
        }
    }

    /// The `NSStatusItem` button SwiftUI created for the `MenuBarExtra`.
    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = window.contentView?.subviews
                .compactMap({ $0 as? NSStatusBarButton }).first {
                return button
            }
            if let button = window.contentView as? NSStatusBarButton {
                return button
            }
        }
        // Fallback: some macOS versions expose the button directly on a window.
        return NSApp.windows.compactMap { $0.value(forKey: "statusItem") as? NSStatusItem }.first?.button
    }

    private static func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings", comment: "Menu bar context menu item"),
            action: #selector(AppDelegate.openSettings),
            keyEquivalent: ",")
        settingsItem.target = NSApp.delegate
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit DeployBar", comment: "Menu bar context menu item"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        // Pop the menu at the button; `popUpMenu` blocks until dismissed.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    /// Not `showSettingsWindow:`: since macOS 14 SwiftUI refuses that selector
    /// ("Please use SettingsLink for opening the Settings scene.") and this
    /// menu item silently did nothing.
    @MainActor @objc func openSettings() {
        SettingsNavigation.shared.open()
    }

    /// A click on a widget link launches the containing app with the URL
    /// instead of opening it (measured in the widget spike). Pass web links
    /// straight to the browser; DeployBar registers no scheme of its own.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
    }
}
