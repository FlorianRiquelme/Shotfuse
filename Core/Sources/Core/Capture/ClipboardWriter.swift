#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Writes the PNG bytes of a finalized `.shot/`'s `master.png` to
/// `NSPasteboard.general`. This is the pipeline step that satisfies the
/// SPEC §2 Weekend 1 DoD clause "a PNG of the selection is on the clipboard"
/// — paired with the atomic `.shot/` write.
///
/// Best-effort by design: any failure (read error, headless environment,
/// pasteboard unavailable) is logged and swallowed so the capture remains
/// successful from the user's perspective. The `.shot/` on disk is the
/// source of truth; `shot last --copy` (SPEC §16) always recovers if the
/// clipboard write flaked.
public enum ClipboardWriter {

    /// Copies `<finalURL>/master.png` onto the general pasteboard as PNG.
    /// Returns `true` on success, `false` otherwise.
    @discardableResult
    public static func copyMaster(at finalURL: URL) -> Bool {
        let masterURL = finalURL.appendingPathComponent("master.png")
        guard let data = try? Data(contentsOf: masterURL) else {
            return false
        }
        return copyPNGData(data)
    }

    /// Writes raw PNG bytes to `NSPasteboard.general`. Factored out so the
    /// CLI's `shot last --copy` path can share the same semantics.
    @discardableResult
    public static func copyPNGData(_ data: Data) -> Bool {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setData(data, forType: .png)
        #else
        return false
        #endif
    }
}
