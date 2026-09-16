import AppKit
import SwiftUI

/// Owns the menu bar icon and the panel it drops down, replacing SwiftUI's
/// `MenuBarExtra(.window)`.
///
/// ## Why this exists rather than `MenuBarExtra`
///
/// `MenuBarExtra(.window)` cannot be given a translucent material. Dumped from
/// a live panel on macOS 26, its content view holds **no `NSVisualEffectView`**
/// — just two flat `_NSGraphicsView`s, one an opaque grey fill
/// (`0.96, 0.96, 0.96, alpha 1.0`). That opaque rectangle is the flat "grey
/// block" the panel used to be, and nothing behind the window read through it.
///
/// Supplying the material from outside was tried twice and shipped a panel
/// that drew *nothing* both times — once by inserting an effect view under the
/// content, once by clearing the opaque fill on its own layer (1.2.2, reverted
/// in 1.2.3; that one even rendered correctly in Debug and failed only in
/// Release). `MenuBarExtraHostingView` tolerates no rewriting of its backing
/// layers at all.
///
/// Owning the window sidesteps the whole problem: an `NSVisualEffectView` is
/// simply this panel's content view, which is the ordinary, supported way to
/// build a translucent panel.
///
/// ## What this has to reimplement
///
/// `MenuBarExtra` handled show/hide, outside-click dismissal and positioning.
/// All three live here now. The right-click menu actually gets *simpler*: it
/// used to hunt through `NSApp.windows` for SwiftUI's private status button,
/// and now the button is ours.
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    /// Dismisses the panel when the user clicks anywhere else. `MenuBarExtra`
    /// did this for free; a plain panel stays up until told otherwise.
    private var outsideClickMonitor: Any?
    private let onRightClick: (NSStatusBarButton) -> Void

    /// - Parameters:
    ///   - content: the panel's SwiftUI content — `PopoverView` in the app.
    ///   - onRightClick: pops the context menu. Passed in so this type stays
    ///     unaware of what the menu contains.
    init<Content: View>(content: Content,
                        onRightClick: @escaping (NSStatusBarButton) -> Void) {
        self.onRightClick = onRightClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // .borderless: no titlebar. .nonactivatingPanel: clicking the panel
        // must not make DeployBar the active app — an LSUIElement menu bar app
        // has no business stealing focus from whatever the user is doing.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 396),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered,
                        defer: false)
        super.init()

        panel.isFloatingPanel = true
        // .statusBar keeps it above ordinary windows, matching where a menu bar
        // panel belongs in the stacking order.
        panel.level = .statusBar
        // Without this the panel vanishes the moment the app resigns active,
        // which for a non-activating panel is immediately.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // The material, at last — this window is ours, so an effect view here
        // is just an effect view.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        // .active, not .followsWindowActiveState: a non-activating panel is
        // never "active", and the follow mode would render it flat grey.
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        panel.contentView = backdrop
        // The content sizes itself; the panel follows it rather than the other
        // way round, so the fixed contentRect above is only a starting size.
        panel.setContentSize(hosting.fittingSize)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            // Both, so the right click reaches `statusItemClicked` instead of
            // being swallowed as a no-op.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }

    /// Matches the rounding macOS draws on menu bar panels.
    private static let cornerRadius: CGFloat = 11

    /// Updates the menu bar icon. Called as the aggregate state changes, since
    /// the icon is no longer a SwiftUI view that could observe the store
    /// itself. The artwork still comes from `MenuBarIcon`, so the asset and
    /// accessibility rules stay in one place.
    func setIcon(for state: IconState) {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image(for: state)
        button.toolTip = MenuBarIcon.accessibilityLabel(for: state)
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseDown {
            // Never leave the panel up behind a context menu.
            hide()
            onRightClick(button)
            return
        }
        panel.isVisible ? hide() : show(from: button)
    }

    private func show(from button: NSStatusBarButton) {
        position(below: button)
        // orderFrontRegardless, not makeKeyAndOrderFront: this panel must show
        // without the app becoming active.
        panel.orderFrontRegardless()
        startWatchingForOutsideClicks()

    }

    func hide() {
        stopWatchingForOutsideClicks()
        panel.orderOut(nil)
    }

    /// Hangs the panel under the menu bar icon.
    private func position(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? iconFrame
        panel.setFrameOrigin(Self.panelOrigin(iconFrame: iconFrame,
                                              panelSize: panel.frame.size,
                                              visibleFrame: visible))
    }

    /// Centres the panel under the icon and clamps it to the screen, so an icon
    /// near either edge cannot push the panel half off it.
    ///
    /// Pure and `static` so the geometry is testable without a real status item
    /// — this is the part that breaks silently, and `MenuBarExtra` used to own
    /// it.
    nonisolated static func panelOrigin(iconFrame: NSRect,
                                        panelSize: NSSize,
                                        visibleFrame: NSRect) -> NSPoint {
        var origin = NSPoint(x: iconFrame.midX - panelSize.width / 2,
                             y: iconFrame.minY - panelSize.height - gapBelowMenuBar)
        let leftLimit = visibleFrame.minX + screenInset
        let rightLimit = visibleFrame.maxX - panelSize.width - screenInset
        // max(leftLimit, …) last: for a panel wider than the screen the limits
        // invert, and clamping the other way round would push it off the left.
        origin.x = max(leftLimit, min(origin.x, rightLimit))
        return origin
    }

    nonisolated static let gapBelowMenuBar: CGFloat = 6
    nonisolated static let screenInset: CGFloat = 8

    /// A global monitor sees clicks in *other* apps; a local one sees clicks in
    /// ours. Both are needed, or clicking DeployBar's own Settings window would
    /// leave the panel hanging.
    private func startWatchingForOutsideClicks() {
        stopWatchingForOutsideClicks()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.hide()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            // A click inside the panel is not an outside click; neither is one
            // on the status item, which toggles on its own.
            if event.window !== self.panel && event.window !== self.statusItem.button?.window {
                self.hide()
            }
            return event
        }
        outsideClickMonitor = [global, local].compactMap { $0 }
    }

    private func stopWatchingForOutsideClicks() {
        if let monitors = outsideClickMonitor as? [Any] {
            monitors.forEach(NSEvent.removeMonitor)
        }
        outsideClickMonitor = nil
    }

    deinit {
        // Not via stopWatching…: deinit is nonisolated and cannot touch
        // main-actor state, but removeMonitor is safe to call with the values.
        if let monitors = outsideClickMonitor as? [Any] {
            monitors.forEach(NSEvent.removeMonitor)
        }
    }
}
