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
///
/// Verification is unconditional. There is deliberately no "this version predates
/// provenance" exemption: the first release carrying this code is also the first release
/// carrying provenance, so such a branch could never fire in the wild, and a version-keyed
/// way to skip a security check is worth more to an attacker than it is to us.
enum UpdateVerifier {
    enum VerificationError: Error, CustomStringConvertible {
        /// GitHub answered, and the answer was that no attestation exists for this file.
        case notAttested(version: String, digest: String)
        /// GitHub could not be reached or did not give a usable answer. Distinct from
        /// `notAttested` because it says nothing about the file, only about the check.
        case couldNotVerify(version: String, digest: String)

        var description: String {
            switch self {
            case .notAttested(let version, let digest):
                return "release \(version) has no GitHub build provenance (sha256:\(digest))"
            case .couldNotVerify(let version, let digest):
                return "could not reach GitHub to verify release \(version) (sha256:\(digest))"
            }
        }
    }

    /// What the attestations endpoint told us.
    ///
    /// `unattested` and `indeterminate` are kept apart on purpose. Both block an install,
    /// but only the first is a statement about the file; the second is a statement about
    /// the network. Collapsing them produces an alarming, wrong message during an outage.
    enum Outcome: Equatable {
        /// GitHub holds at least one provenance attestation for this digest.
        case attested
        /// GitHub answered definitively: no attestation for this digest.
        case unattested
        /// No usable answer: transport failure, rate limit, 5xx, or an unparseable body.
        case indeterminate
    }

    private static let repo = "celadorastudios/claude-o-meter"

    /// Performs one request and reports `(statusCode, body)`, or nil on transport failure.
    /// Injectable so every branch below is testable without touching the network.
    typealias Fetcher = @Sendable (URL) async -> (statusCode: Int, body: Data)?

    static let defaultFetch: Fetcher = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeOMeter", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        return (http.statusCode, data)
    }

    // MARK: - Digest

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

    // MARK: - Response handling

    /// Number of attestations in the payload, or nil when the body cannot be understood
    /// at all. The nil case matters: a captive portal or intercepting proxy answering 200
    /// with HTML is a failed check, not a file that lacks provenance.
    static func parseAttestationCount(_ data: Data) -> Int? {
        guard let payload = try? JSONDecoder().decode(AttestationResponse.self, from: data) else {
            return nil
        }
        return (payload.attestations ?? []).count
    }

    /// Convenience over `parseAttestationCount` for callers that only need a yes/no.
    /// An unreadable body reads as "no", so this can never spoof a pass.
    static func hasAttestation(inResponseBody data: Data) -> Bool {
        (parseAttestationCount(data) ?? 0) > 0
    }

    /// Maps one HTTP response onto an `Outcome`. Pure, so the whole decision table is
    /// testable directly.
    ///
    /// 404 is the documented, verified answer for a digest GitHub has never attested, so
    /// it is definitive. Everything else that is not a usable 200 (403 rate limit, 5xx,
    /// redirects, an unreadable body) means the check did not happen.
    static func classify(statusCode: Int, body: Data) -> Outcome {
        switch statusCode {
        case 200:
            guard let count = parseAttestationCount(body) else { return .indeterminate }
            return count > 0 ? .attested : .unattested
        case 404:
            return .unattested
        default:
            return .indeterminate
        }
    }

    /// Asks GitHub about `digest`, retrying only when the answer was indeterminate.
    ///
    /// A definitive answer is never retried: retrying a 404 just delays the inevitable,
    /// and retrying a 200 would be pointless. Retries exist for the outage case, which is
    /// the only one that might resolve itself.
    static func attestationOutcome(digest: String,
                                   attempts: Int = 3,
                                   retryDelay: Duration = .seconds(2),
                                   fetch: Fetcher = defaultFetch) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/attestations/sha256:\(digest)") else {
            return .indeterminate
        }

        let total = max(1, attempts)
        for attempt in 1...total {
            if let (status, body) = await fetch(url) {
                let outcome = classify(statusCode: status, body: body)
                if outcome != .indeterminate { return outcome }
            }
            if attempt < total {
                try? await Task.sleep(for: retryDelay * attempt)
            }
        }
        return .indeterminate
    }

    // MARK: - Verification

    /// Throws unless GitHub confirms provenance for this exact file.
    ///
    /// Fails closed on an indeterminate result. That is deliberate: anyone able to swap
    /// the release asset is also able to drop packets to api.github.com, so treating an
    /// unreachable API as a pass would let the same adversary the check exists to stop
    /// bypass it by blocking one host.
    static func verify(zipAt url: URL,
                       version: String,
                       attempts: Int = 3,
                       retryDelay: Duration = .seconds(2),
                       fetch: Fetcher = defaultFetch) async throws {
        let digest = try sha256(ofFileAt: url)

        switch await attestationOutcome(digest: digest,
                                        attempts: attempts,
                                        retryDelay: retryDelay,
                                        fetch: fetch) {
        case .attested:
            AppLog.shared.info("update \(version): build provenance verified", category: "updates")

        case .unattested:
            AppLog.shared.error("update \(version): no build provenance for sha256:\(digest); refusing to install",
                                category: "updates")
            throw VerificationError.notAttested(version: version, digest: digest)

        case .indeterminate:
            AppLog.shared.error("update \(version): could not reach GitHub to check provenance for sha256:\(digest); refusing to install",
                                category: "updates")
            throw VerificationError.couldNotVerify(version: version, digest: digest)
        }
    }

    /// Only the presence and count of attestations matters, so the entries stay opaque.
    struct AttestationResponse: Decodable {
        struct Entry: Decodable {}
        let attestations: [Entry]?
    }
}
