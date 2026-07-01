import AppKit

/// Thin wrapper over the general pasteboard so call sites (and the store) don't
/// import AppKit directly and stay easy to reason about.
enum Pasteboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
