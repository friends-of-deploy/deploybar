import AppKit

/// TEMPORARY — macOS 27 investigation, branch diag/macos-27-panel. Not for release.
///
/// Logs, to /tmp/deploybar-diag.log, every mouse/scroll event this process
/// receives and what the panel window's view tree hit-tests it to, plus a dump
/// of every window and its view hierarchy whenever a window becomes key or
/// changes occlusion.
///
/// `defaults write io.eightlines.deploybar.DeployBar DiagDisableStyler -bool YES`
/// turns PopoverPanelStyler into a no-op, for an A/B against the styler.
enum DiagnosticProbe {
    static var stylerDisabled: Bool {
        UserDefaults.standard.bool(forKey: "DiagDisableStyler")
    }

    private static let path = "/tmp/deploybar-diag.log"
    private static var monitor: Any?

    static func install() {
        FileManager.default.createFile(atPath: path, contents: nil)
        let info = ProcessInfo.processInfo
        log("=== launch os=\(info.operatingSystemVersionString) stylerDisabled=\(stylerDisabled)")

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .rightMouseDown, .mouseEntered, .mouseExited]
        ) { event in
            record(event)
            return event
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                log("--- \(name.rawValue) \(describe(window)) appActive=\(NSApp.isActive)")
                if name == NSWindow.didChangeOcclusionStateNotification, window.isVisible {
                    // Let SwiftUI finish building the panel before dumping it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dumpAll() }
                }
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                log("--- \(name.rawValue)")
            }
        }
    }

    private static func record(_ event: NSEvent) {
        var line = "event \(event.type.rawValue) loc=\(event.locationInWindow) appActive=\(NSApp.isActive)"
        if event.type == .scrollWheel {
            line += " dy=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)"
        }
        guard let window = event.window else {
            log(line + " window=nil windowNumber=\(event.windowNumber)")
            return
        }
        line += " \(describe(window))"
        if let frameView = window.contentView?.superview {
            let point = frameView.convert(event.locationInWindow, from: nil)
            let hit = frameView.hitTest(point)
            line += " hit=" + chain(hit)
        }
        log(line)
    }

    static func dumpAll() {
        log("=== windows")
        for window in NSApp.windows {
            log(describe(window))
            if let root = window.contentView?.superview ?? window.contentView {
                dump(root, depth: 1)
            }
        }
    }

    private static func dump(_ view: NSView, depth: Int) {
        guard depth < 40 else { return }
        let pad = String(repeating: "  ", count: depth)
        var flags: [String] = []
        if view.isHidden { flags.append("hidden") }
        if view.alphaValue < 1 { flags.append("alpha=\(view.alphaValue)") }
        if let layer = view.layer { flags.append("layer=\(type(of: layer))") }
        log("\(pad)\(type(of: view)) frame=\(view.frame) \(flags.joined(separator: " "))")
        for sub in view.subviews { dump(sub, depth: depth + 1) }
    }

    private static func describe(_ window: NSWindow) -> String {
        "win[\(type(of: window)) #\(window.windowNumber) level=\(window.level.rawValue) key=\(window.isKeyWindow) "
            + "canKey=\(window.canBecomeKey) visible=\(window.isVisible) ignoresMouse=\(window.ignoresMouseEvents) "
            + "frame=\(window.frame) style=\(window.styleMask.rawValue) content=\(window.contentView.map { "\(type(of: $0))" } ?? "nil")]"
    }

    private static func chain(_ view: NSView?) -> String {
        var names: [String] = []
        var current = view
        while let v = current, names.count < 12 {
            names.append("\(type(of: v))")
            current = v.superview
        }
        return view == nil ? "nil" : names.joined(separator: " < ")
    }

    static func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}
