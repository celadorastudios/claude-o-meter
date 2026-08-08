import XCTest
@testable import ClaudeOMeter

/// What the user is told when an update does not install.
///
/// The whole point of verifying provenance is lost if every failure looks the same.
/// Someone told only "the update failed" reasonably concludes the updater is flaky and
/// goes to download it by hand — which is the one thing they must not do when the
/// download is the part that failed the check.
final class UpdateFailureMessageTests: XCTestCase {

    private typealias Failure = UsageStore.UpdateInstallFailure

    // MARK: - Mapping errors onto what the user needs to know

    func testMissingProvenanceIsReportedAsAnUnverifiedDownload() {
        let error = UpdateVerifier.VerificationError.notAttested(version: "0.13.0", digest: "abc")
        XCTAssertEqual(Failure.from(error, version: "0.13.0"), .unverified("0.13.0"))
    }

    func testUnreachableGitHubIsReportedAsUnverifiable() {
        let error = UpdateVerifier.VerificationError.couldNotVerify(version: "0.13.0", digest: "abc")
        XCTAssertEqual(Failure.from(error, version: "0.13.0"), .unverifiable("0.13.0"))
    }

    func testOtherErrorsFallBackToAPlainFailure() {
        for error: Error in [UpdateInstaller.InstallError.downloadFailed,
                             UpdateInstaller.InstallError.unzipFailed,
                             UpdateInstaller.InstallError.appNotFound] {
            XCTAssertEqual(Failure.from(error, version: "0.13.0"), .failed("0.13.0"))
        }
    }

    // MARK: - Only a bad artifact is a security failure

    /// This flag decides both the alarm level and whether the user is sent to the
    /// Releases page, so the two unverifiable-vs-unverified cases must not blur.
    func testOnlyAMissingAttestationCountsAsASecurityFailure() {
        XCTAssertTrue(Failure.unverified("0.13.0").isSecurityFailure)
        XCTAssertFalse(Failure.unverifiable("0.13.0").isSecurityFailure)
        XCTAssertFalse(Failure.failed("0.13.0").isSecurityFailure)
    }

    // MARK: - The messages themselves

    /// A blocked download must not be described in a way that invites installing it by
    /// hand, because that would walk straight around the check that just refused it.
    func testUnverifiedMessageWarnsAgainstInstallingManually() {
        let message = Failure.unverified("0.13.0").message
        XCTAssertTrue(message.contains("0.13.0"))
        XCTAssertTrue(message.lowercased().contains("not the file we published"))
        XCTAssertTrue(message.lowercased().contains("do not install it manually"))
    }

    /// An outage must not be reported as though the download were forged.
    func testUnverifiableMessageDoesNotAccuseTheDownload() {
        let message = Failure.unverifiable("0.13.0").message
        XCTAssertTrue(message.lowercased().contains("doesn't mean the download is unsafe"))
        XCTAssertFalse(message.lowercased().contains("not the file we published"))
    }

    /// A plain failure should reassure that nothing was damaged, since the installer
    /// verifies before it writes anything.
    func testPlainFailureSaysTheCurrentVersionIsIntact() {
        XCTAssertTrue(Failure.failed("0.13.0").message.lowercased().contains("unchanged"))
    }

    func testEveryMessageNamesTheVersion() {
        for failure: Failure in [.unverified("1.2.3"), .unverifiable("1.2.3"), .failed("1.2.3")] {
            XCTAssertTrue(failure.message.contains("1.2.3"), "\(failure) should name the version")
        }
    }

    /// The three cases must be distinguishable to the user, not just to the code.
    func testTheThreeMessagesAreAllDifferent() {
        let messages = Set([Failure.unverified("1.0.0").message,
                            Failure.unverifiable("1.0.0").message,
                            Failure.failed("1.0.0").message])
        XCTAssertEqual(messages.count, 3)
    }
}
