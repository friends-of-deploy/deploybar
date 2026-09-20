import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let state: OnboardingState
    private var makeContent: (() -> NSView)?

    init(state: OnboardingState, accounts: AccountStore, store: DeploymentStore, settings: SettingsStore) {
        self.state = state
        let window = OnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.borderless, .closable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Welcome to DeployBar")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        makeContent = { [weak self] in NSHostingView(rootView: OnboardingView(
            state: state, accounts: accounts, store: store, settings: settings,
            finish: { [weak self] in
                state.complete()
                self?.close()
            },
            dismiss: { [weak self] in self?.close() })) }
        window.contentView = nil
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        // Release the hosting tree while retaining the current onboarding step.
        window?.contentView = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        if window?.contentView == nil {
            if state.isComplete { state.step = .welcome }
            window?.contentView = makeContent?()
        }
        state.markPresented()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Borderless windows need explicit keyboard eligibility for text input and
/// normal macOS close commands, even though their chrome lives in SwiftUI.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) { close() }
    override func cancelOperation(_ sender: Any?) { close() }
}
