@testable import ClaudeOMeter
import XCTest

final class ProjectAlertTests: XCTestCase {

    func testProjectAlertFiresWhenCostExceedsLimit() {
        let settings = AlertSettings(projectThresholds: ["myapp": 10.0])
        let decision = AlertManager.decide(
            todayCost: 5.0, monthCost: 50.0,
            projectDailyCosts: ["myapp": 12.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")
        XCTAssertEqual(decision.notifications.count, 1)
        XCTAssertTrue(decision.notifications[0].title.contains("Project budget"))
        XCTAssertTrue(decision.notifications[0].body.contains("myapp"))
    }

    func testProjectAlertDoesNotFireBelowThreshold() {
        let settings = AlertSettings(projectThresholds: ["myapp": 10.0])
        let decision = AlertManager.decide(
            todayCost: 5.0, monthCost: 50.0,
            projectDailyCosts: ["myapp": 8.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")
        XCTAssertTrue(decision.notifications.isEmpty)
    }

    func testProjectAlertFiresOncePerDay() {
        let settings = AlertSettings(projectThresholds: ["myapp": 10.0])
        let firstFired = AlertManager.decide(
            todayCost: 5.0, monthCost: 50.0,
            projectDailyCosts: ["myapp": 15.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")
        XCTAssertEqual(firstFired.notifications.count, 1)

        let secondFired = AlertManager.decide(
            todayCost: 5.0, monthCost: 50.0,
            projectDailyCosts: ["myapp": 20.0],
            settings: settings, lastAlertDay: firstFired.lastAlertDay, today: "2025-07-15")
        XCTAssertTrue(secondFired.notifications.isEmpty)
    }

    func testProjectAlertFiresAgainNextDay() {
        let settings = AlertSettings(projectThresholds: ["myapp": 10.0])
        let day1 = AlertManager.decide(
            todayCost: 5.0, monthCost: 50.0,
            projectDailyCosts: ["myapp": 15.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")

        let day2 = AlertManager.decide(
            todayCost: 5.0, monthCost: 55.0,
            projectDailyCosts: ["myapp": 12.0],
            settings: settings, lastAlertDay: day1.lastAlertDay, today: "2025-07-16")
        XCTAssertEqual(day2.notifications.count, 1)
    }

    func testProjectAlertFiresForMultipleProjects() {
        let settings = AlertSettings(projectThresholds: ["app1": 5.0, "app2": 8.0])
        let decision = AlertManager.decide(
            todayCost: 20.0, monthCost: 100.0,
            projectDailyCosts: ["app1": 6.0, "app2": 10.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")
        XCTAssertEqual(decision.notifications.count, 2)
    }

    func testProjectAlertKeyNamespacedFromGlobal() {
        let settings = AlertSettings(dailyThreshold: 50.0, projectThresholds: ["myapp": 10.0])
        let decision = AlertManager.decide(
            todayCost: 55.0, monthCost: 100.0,
            projectDailyCosts: ["myapp": 15.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")
        XCTAssertNotNil(decision.lastAlertDay["project:myapp"])
        XCTAssertNotNil(decision.lastAlertDay["daily"])
        XCTAssertNotEqual(decision.lastAlertDay["project:myapp"], decision.lastAlertDay["daily"])
    }

    func testProjectAlertSuppressedWhenNoThreshold() {
        let settings = AlertSettings(projectThresholds: [:])
        let decision = AlertManager.decide(
            todayCost: 5.0, monthCost: 50.0,
            projectDailyCosts: ["myapp": 100.0],
            settings: settings, lastAlertDay: [:], today: "2025-07-15")
        XCTAssertTrue(decision.notifications.isEmpty)
    }

    func testOldSettingsDecodesWithoutProjectThresholds() throws {
        let json = """
        {"dailyThreshold": 20.0, "monthlyThreshold": 100.0, "tipsEnabled": true, "approachPercent": 80}
        """
        let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.projectThresholds, [:])
        XCTAssertEqual(settings.dailyThreshold, 20.0)
    }
}
