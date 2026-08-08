import Foundation
import AppKit

enum UpdateChecker {
    static let projectPageURL  = URL(string: "https://github.com/celadorastudios/claude-o-meter")!
    static let releasesPageURL = URL(string: "https://github.com/celadorastudios/claude-o-meter/releases")!

    private static let apiURL = URL(string: "https://api.github.com/repos/celadorastudios/claude-o-meter/releases/latest")!

    struct UpdateInfo {
        let version: String
        let downloadURL: URL?   // nil if release has no zip asset
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    /// Returns UpdateInfo if a newer version exists, otherwise nil.
    /// Dev builds ("dev" or empty) are treated as 0.0.0 so any real release appears newer.
    static func checkForUpdate(current: String) async -> UpdateInfo? {
        guard !current.isEmpty else { return nil }
        let effective = current == "dev" ? "0.0.0" : current

        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeOMeter/\(current)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return nil
        }

        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isNewer(latest, than: effective) else { return nil }

        let zipAsset = release.assets.first { $0.name.hasSuffix(".zip") }
        let downloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadUrl) }
        return UpdateInfo(version: latest, downloadURL: downloadURL)
    }

    static func openReleasesPage() {
        NSWorkspace.shared.open(releasesPageURL)
    }

    /// Numeric semver comparison: "1.10.0" > "1.9.0" correctly.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").compactMap { Int($0) } }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }
}
