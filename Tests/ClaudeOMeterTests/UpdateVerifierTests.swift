import XCTest
import CryptoKit
@testable import ClaudeOMeter

/// Counts how many times the injected fetcher was called, so "did it retry?" and
/// "did it stop retrying?" can both be asserted rather than inferred.
private actor CallCounter {
    private(set) var count = 0
    func bump() -> Int {
        count += 1
        return count
    }
}

final class UpdateVerifierTests: XCTestCase {

    // MARK: - Fixtures

    private static let attestedBody = Data(#"{"attestations":[{"bundle":{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}}]}"#.utf8)
    private static let emptyListBody = Data(#"{"attestations":[]}"#.utf8)
    private static let notFoundBody = Data(#"{"message":"Not Found","status":"404"}"#.utf8)

    /// A real file on disk, since `verify` hashes before it ever reaches the network.
    private func makeZip(contents: String = "payload") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeometer-verify-\(UUID().uuidString).zip")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fetcher(status: Int, body: Data) -> UpdateVerifier.Fetcher {
        { _ in (statusCode: status, body: body) }
    }

    // MARK: - classify: the whole decision table

    func testClassifiesPopulatedListAsAttested() {
        XCTAssertEqual(UpdateVerifier.classify(statusCode: 200, body: Self.attestedBody), .attested)
    }

    func testClassifiesEmptyListAsUnattested() {
        XCTAssertEqual(UpdateVerifier.classify(statusCode: 200, body: Self.emptyListBody), .unattested)
    }

    // The verified real-world answer for a digest GitHub has never attested. Definitive,
    // so it must read as a statement about the file rather than about the network.
    func testClassifiesNotFoundAsUnattested() {
        XCTAssertEqual(UpdateVerifier.classify(statusCode: 404, body: Self.notFoundBody), .unattested)
    }

    // A 200 we cannot parse is a failed check, not a file lacking provenance. A captive
    // portal or intercepting proxy answering with HTML lands here, and calling that
    // "unattested" would accuse the user of holding a forged download.
    func testClassifiesUnreadableBodyAsIndeterminate() {
        XCTAssertEqual(UpdateVerifier.classify(statusCode: 200, body: Data("<html>login</html>".utf8)),
                       .indeterminate)
        XCTAssertEqual(UpdateVerifier.classify(statusCode: 200, body: Data()), .indeterminate)
    }

    // Unauthenticated api.github.com allows 60 requests an hour per IP, so a shared NAT
    // can realistically produce this. It must not be mistaken for a missing attestation.
    func testClassifiesRateLimitAndServerErrorsAsIndeterminate() {
        for status in [401, 403, 429, 500, 502, 503, 301] {
            XCTAssertEqual(UpdateVerifier.classify(statusCode: status, body: Data()),
                           .indeterminate,
                           "HTTP \(status) says nothing about the file and must be indeterminate")
        }
    }

    // MARK: - Retry behaviour

    func testTransportFailureIsRetriedThenReportedIndeterminate() async {
        let counter = CallCounter()
        let outcome = await UpdateVerifier.attestationOutcome(
            digest: String(repeating: "a", count: 64),
            attempts: 3,
            retryDelay: .zero,
            fetch: { _ in _ = await counter.bump(); return nil })

        XCTAssertEqual(outcome, .indeterminate)
        let calls = await counter.count
        XCTAssertEqual(calls, 3, "a transport failure should be retried up to the attempt limit")
    }

    func testRecoversWhenARetrySucceeds() async {
        let counter = CallCounter()
        let outcome = await UpdateVerifier.attestationOutcome(
            digest: String(repeating: "b", count: 64),
            attempts: 3,
            retryDelay: .zero,
            fetch: { [attested = Self.attestedBody] _ in
                let n = await counter.bump()
                return n < 3 ? nil : (statusCode: 200, body: attested)
            })

        XCTAssertEqual(outcome, .attested, "a transient outage must not permanently block an update")
    }

    // Retrying a definitive answer only delays it. This also pins that a 404 costs exactly
    // one request, so a genuinely unattested file fails fast instead of after a backoff.
    func testDefinitiveAnswersAreNotRetried() async {
        for (status, body) in [(404, Self.notFoundBody), (200, Self.attestedBody), (200, Self.emptyListBody)] {
            let counter = CallCounter()
            _ = await UpdateVerifier.attestationOutcome(
                digest: String(repeating: "c", count: 64),
                attempts: 3,
                retryDelay: .zero,
                fetch: { _ in
                    _ = await counter.bump()
                    return (statusCode: status, body: body)
                })

            let calls = await counter.count
            XCTAssertEqual(calls, 1, "HTTP \(status) is definitive and must not be retried")
        }
    }

    // MARK: - verify: what actually gates an install

    func testVerifyAcceptsAnAttestedArtifact() async throws {
        let zip = try makeZip()
        try await UpdateVerifier.verify(zipAt: zip,
                                        version: "0.12.0",
                                        retryDelay: .zero,
                                        fetch: fetcher(status: 200, body: Self.attestedBody))
    }

    func testVerifyRejectsAnUnattestedArtifact() async throws {
        let zip = try makeZip()
        do {
            try await UpdateVerifier.verify(zipAt: zip,
                                            version: "0.12.0",
                                            retryDelay: .zero,
                                            fetch: fetcher(status: 404, body: Self.notFoundBody))
            XCTFail("an unattested artifact must not install")
        } catch let error as UpdateVerifier.VerificationError {
            guard case .notAttested = error else {
                return XCTFail("expected .notAttested, got \(error)")
            }
        }
    }

    // Fails closed. Anyone able to substitute the release asset can also block
    // api.github.com, so an unreachable API must not be a pass.
    func testVerifyRefusesWhenTheCheckCannotBeCompleted() async throws {
        let zip = try makeZip()
        do {
            try await UpdateVerifier.verify(zipAt: zip,
                                            version: "0.12.0",
                                            attempts: 2,
                                            retryDelay: .zero,
                                            fetch: { _ in nil })
            XCTFail("an unverifiable artifact must not install")
        } catch let error as UpdateVerifier.VerificationError {
            guard case .couldNotVerify = error else {
                return XCTFail("expected .couldNotVerify, got \(error)")
            }
        }
    }

    // The two failures are reported separately so the user is not told their download is
    // forged when GitHub is merely unreachable.
    func testTheTwoFailuresAreDistinguishable() {
        let missing = UpdateVerifier.VerificationError.notAttested(version: "1.0.0", digest: "abc")
        let unreachable = UpdateVerifier.VerificationError.couldNotVerify(version: "1.0.0", digest: "abc")

        XCTAssertTrue(missing.description.contains("no GitHub build provenance"))
        XCTAssertTrue(unreachable.description.contains("could not reach GitHub"))
        XCTAssertNotEqual(missing.description, unreachable.description)
    }

    // There is no version-keyed exemption. An older version string must not buy a pass,
    // which is the property that replaced the previous `firstAttestedVersion` threshold.
    func testNoVersionEscapesVerification() async throws {
        let zip = try makeZip()
        for version in ["0.0.1", "0.11.0", "0.11.9", "dev", "", "not-a-version"] {
            do {
                try await UpdateVerifier.verify(zipAt: zip,
                                                version: version,
                                                retryDelay: .zero,
                                                fetch: fetcher(status: 404, body: Self.notFoundBody))
                XCTFail("version '\(version)' must not skip verification")
            } catch is UpdateVerifier.VerificationError {
                // expected
            }
        }
    }

    // MARK: - Digest

    func testSHA256MatchesKnownVector() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeometer-digest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("abc".utf8).write(to: url)

        XCTAssertEqual(try UpdateVerifier.sha256(ofFileAt: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // The digest is streamed in 4 MB chunks, so a payload spanning several chunks has to
    // produce the same result as hashing it in one go.
    func testSHA256StreamsAcrossChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeometer-digest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        var payload = Data()
        for i in 0..<(9 * 1024 * 1024 / 8) {
            withUnsafeBytes(of: UInt64(i).littleEndian) { payload.append(contentsOf: $0) }
        }
        try payload.write(to: url)

        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try UpdateVerifier.sha256(ofFileAt: url), expected)
    }

    func testSHA256OfEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudeometer-digest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data().write(to: url)

        XCTAssertEqual(try UpdateVerifier.sha256(ofFileAt: url),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // A digest that differs by one byte must not match the attested one. Cheap, but it is
    // the property the whole scheme rests on.
    func testDigestChangesWhenTheArtifactChanges() throws {
        let a = try makeZip(contents: "payload")
        let b = try makeZip(contents: "payloae")
        XCTAssertNotEqual(try UpdateVerifier.sha256(ofFileAt: a),
                          try UpdateVerifier.sha256(ofFileAt: b))
    }
}
