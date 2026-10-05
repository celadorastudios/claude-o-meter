import SwiftUI
import AppKit

/// Claude Code robot icon loaded from the app bundle.
struct ClaudeMark: View {
    var size: CGFloat = 14
    var color: Color = .accentColor  // unused — kept for call-site compatibility

    var body: some View {
        BundleImage(name: "claude-code-icon", size: size)
    }
}

/// Loads a PNG from the app bundle by name, falling back to an SF Symbol.
struct BundleImage: View {
    let name: String
    let size: CGFloat
    var template: Bool = false
    var fallback: String = "cpu"

    private var nsImage: NSImage? {
        let res = Bundle.main.resourceURL
        let candidates = ["\(name)@2x", "\(name)"]
        for file in candidates {
            if let url = res?.appendingPathComponent("\(file).png"),
               let img = configured(NSImage(contentsOf: url)) {
                return img
            }
        }
        for file in candidates {
            if let url = Bundle.main.url(forResource: file, withExtension: "png",
                                         subdirectory: "ClaudeOMeter_ClaudeOMeter.bundle"),
               let img = configured(NSImage(contentsOf: url)) {
                return img
            }
        }
        // swift run / swift test: Bundle.main isn't the app bundle at all, and the
        // sub-bundle's on-disk layout (flat vs. nested under its own Contents/Resources/)
        // varies by toolchain. Bundle.module already knows how to resolve either, so it's
        // the only lookup that works here (see Persistence.loadPricing() for the same pattern).
        for file in candidates {
            if let url = Bundle.module.url(forResource: file, withExtension: "png"),
               let img = configured(NSImage(contentsOf: url)) {
                return img
            }
        }
        return nil
    }

    private func configured(_ img: NSImage?) -> NSImage? {
        guard let img else { return nil }
        img.size = NSSize(width: size, height: size)
        if template { img.isTemplate = true }
        return img
    }

    var body: some View {
        if let img = nsImage {
            Image(nsImage: img)
                .renderingMode(template ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.8))
        }
    }
}
