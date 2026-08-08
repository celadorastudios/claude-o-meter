import XCTest
@testable import ClaudeOMeter

/// Response shapes from GitHub's attestations endpoint. Verified against the real API:
/// a digest that was never attested returns 404 rather than an empty list, so "no
/// attestations" has to be recognised from both shapes.
final class AttestationParsingTests: XCTestCase {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testRecognisesAPopulatedAttestationList() {
        let json = """
        {"attestations":[{"bundle":{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json",
        "verificationMaterial":{},"dsseEnvelope":{}},"repository_id":123}]}
        """
        XCTAssertTrue(UpdateVerifier.hasAttestation(inResponseBody: body(json)))
    }

    func testTreatsEmptyListAsUnattested() {
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body(#"{"attestations":[]}"#)))
    }

    func testTreatsMissingKeyAsUnattested() {
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body(#"{}"#)))
    }

    func testTreatsNullListAsUnattested() {
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body(#"{"attestations":null}"#)))
    }

    // What the API actually returns for a digest it has never seen.
    func testTreatsNotFoundBodyAsUnattested() {
        let json = #"{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}"#
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body(json)))
    }

    func testTreatsMalformedBodyAsUnattested() {
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body("not json at all")))
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: Data()))
    }

    // An attacker controlling the response body should not be able to spoof a pass with a
    // wrong-typed field; a decode failure must read as unattested.
    func testTreatsWronglyTypedListAsUnattested() {
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body(#"{"attestations":"yes"}"#)))
        XCTAssertFalse(UpdateVerifier.hasAttestation(inResponseBody: body(#"{"attestations":5}"#)))
    }
}
