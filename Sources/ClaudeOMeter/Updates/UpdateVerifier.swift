import Foundation
import CryptoKit

/// Confirms that a downloaded release artifact was really built by this project's
/// GitHub Actions workflow.
///
/// The `.app` is ad-hoc signed, so its own signature proves nothing about origin. GitHub
/// build provenance does: the release workflow records an attestation binding the exact
/// file digest to the commit and workflow run that produced it.
///
/// Verification asks api.github.com whether an attestation exists for this digest under
/// this repository. That is not an offline Sigstore check, but the trust anchor is TLS to
/// GitHub, which is already what we trust to serve the download. Someone who swapped the
/// release asset cannot mint a matching attestation without running the workflow in this
/// repo. It uses only URLSession and CryptoKit, so the user installs no extra tooling.
enum UpdateVerifier {
    enum VerificationError: Error, CustomStringConvertible {
        case notAttested(version: String)

        var description: String {
            switch self {
            case .notAttested(let version):
                return "release \(version) has no GitHub build provenance"
            }
        }
    }

    /// Releases from this version onward are produced by a workflow that records
    /// provenance, so anything at or above it must verify. Earlier releases predate
    /// attestation and are allowed through, otherwise existing users could never update.
    ///
    /// A forged release cannot use that exemption to opt out. `UpdateChecker` only offers
    /// an update whose version is higher than the one running, so any version high enough
    /// to be offered at all is also high enough to require attestation.
    static let firstAttestedVersion = "0.12.0"

    private static let repo = "celadorastudios/claude-o-meter"

    /// Streams the file so a large artifact never has to be held in memory at once.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True when GitHub holds at least one provenance attestation for this digest
    /// under `repo`. A network failure returns false rather than throwing, so the
    /// caller decides whether that is fatal.
    static func isAttested(digest: String) async -> Bool {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/attestations/sha256:\(digest)") else {
            return false
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeOMeter", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(AttestationResponse.self, from: data) else {
            return false
        }
        return !(payload.attestations ?? []).isEmpty
    }

    /// True when `version` is at or above `firstAttestedVersion` and so must verify.
    /// `isNewer(a, than: b)` is `a > b`, so negating it gives `version >= threshold`.
    static func requiresAttestation(version: String) -> Bool {
        !UpdateChecker.isNewer(firstAttestedVersion, than: version)
    }

    /// Throws when `version` is expected to carry provenance but none is present.
    static func verify(zipAt url: URL, version: String) async throws {
        let attestationRequired = requiresAttestation(version: version)

        let digest = try sha256(ofFileAt: url)
        if await isAttested(digest: digest) {
            AppLog.shared.info("update \(version): build provenance verified", category: "updates")
            return
        }

        guard attestationRequired else {
            AppLog.shared.info("update \(version) predates build provenance; installing unverified",
                               category: "updates")
            return
        }
        AppLog.shared.error("update \(version): no build provenance for sha256:\(digest); refusing to install",
                            category: "updates")
        throw VerificationError.notAttested(version: version)
    }

    /// Only the presence and count of attestations matters, so the entries stay opaque.
    private struct AttestationResponse: Decodable {
        struct Entry: Decodable {}
        let attestations: [Entry]?
    }
}
