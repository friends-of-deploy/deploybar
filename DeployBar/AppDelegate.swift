import AppKit
import SwiftUI

/// Owns the menu bar presence: the status item, the panel it drops down, and
/// the icon's right-click menu.
///
/// The panel is a `MenuBarPanelController` rather than SwiftUI's `MenuBarExtra`,
/// because `MenuBarExtra(.window)` cannot be given a translucent material — see
/// that type for the measurements behind it. A side benefit: finding the status
/// button used to mean rummaging through `NSApp.windows` for SwiftUI's private
/// one, and it is now simply ours.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: MenuBarPanelController?
    /// Keeps the menu bar icon in step with the store without a SwiftUI view to
    /// observe it. Cancelled on deinit by virtue of being the only reference.
    private var iconObservation: Task<Void, Never>?

    /// Set by `DeployBarApp.init`, which builds the stores — the delegate is
    /// constructed by `@NSApplicationDelegateAdaptor` before those exist.
    var makePanel: (() -> MenuBarPanelController)?
    /// Polled to drive the icon. Same reason as `makePanel`.
    var currentIconState: (() -> IconState)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let makePanel else { return }
        let controller = makePanel()
        panelController = controller
        if let state = currentIconState?() {
            controller.setIcon(for: state)
        }
        startTrackingIconState()
    }

    /// Mirrors the store's icon state onto the status item.
    ///
    /// A poll rather than an Observation tracking closure: `withObservationTracking`
    /// fires once per change and has to be re-armed, which is easy to get subtly
    /// wrong, and the icon only has five states that change on a network tick
    /// anyway. One second is far below the refresh interval and costs nothing.
    private func startTrackingIconState() {
        iconObservation?.cancel()
        iconObservation = Task { @MainActor [weak self] in
            var last: IconState?
            while !Task.isCancelled {
                guard let self, let state = self.currentIconState?() else { return }
                if state != last {
                    last = state
                    self.panelController?.setIcon(for: state)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Pops the icon's context menu. Handed to the panel controller, which owns
    /// the button and routes right clicks here.
    func showContextMenu(for button: NSStatusBarButton) {
        Self.showContextMenu(for: button)
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

    @objc func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // macOS 14 (Sonoma) renamed the Settings action selector.
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
