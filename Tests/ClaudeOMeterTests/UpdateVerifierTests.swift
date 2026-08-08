import XCTest
import CryptoKit
@testable import ClaudeOMeter

final class UpdateVerifierTests: XCTestCase {

    // MARK: - Attestation threshold

    // Releases built before provenance existed must stay installable, otherwise
    // users on older versions could never update to a version that has it.
    func testVersionsBelowThresholdDoNotRequireAttestation() {
        XCTAssertFalse(UpdateVerifier.requiresAttestation(version: "0.11.0"))
        XCTAssertFalse(UpdateVerifier.requiresAttestation(version: "0.10.1"))
        XCTAssertFalse(UpdateVerifier.requiresAttestation(version: "0.9.0"))
    }

    func testThresholdVersionItselfRequiresAttestation() {
        XCTAssertTrue(UpdateVerifier.requiresAttestation(version: UpdateVerifier.firstAttestedVersion))
    }

    func testVersionsAboveThresholdRequireAttestation() {
        XCTAssertTrue(UpdateVerifier.requiresAttestation(version: "0.12.1"))
        XCTAssertTrue(UpdateVerifier.requiresAttestation(version: "0.13.0"))
        XCTAssertTrue(UpdateVerifier.requiresAttestation(version: "1.0.0"))
    }

    // The exemption for older releases must not become an opt-out. An attacker serving a
    // forged release has to claim a version high enough to be offered as an update at all,
    // and every such version lands above the threshold.
    func testForgedHighVersionCannotEscapeAttestationRequirement() {
        // 0.11.0 is the newest release that predates provenance, so anything a user could
        // be offered as an upgrade from it is at or above the threshold.
        for candidate in ["0.12.0", "1.0.0", "9.9.9", "99.0.0"] {
            XCTAssertTrue(UpdateChecker.isNewer(candidate, than: "0.11.0"),
                          "\(candidate) should be offered as an update")
            XCTAssertTrue(UpdateVerifier.requiresAttestation(version: candidate),
                          "\(candidate) is offerable so it must require attestation")
        }
    }

    // Numeric comparison, not lexicographic: "0.9.0" must not outrank "0.12.0".
    func testThresholdUsesNumericSegmentComparison() {
        XCTAssertFalse(UpdateVerifier.requiresAttestation(version: "0.9.9"))
        XCTAssertTrue(UpdateVerifier.requiresAttestation(version: "0.100.0"))
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
}
