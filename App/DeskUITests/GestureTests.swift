import XCTest

/// The gestures people reach for without thinking: a sheet goes away when dragged down from
/// anywhere on it, and a pushed page goes back when swiped from the left edge.
final class GestureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-network", "mainnet"] + arguments
        app.launch()
        return app
    }

    /// A finger on the middle of the screen, flicked to the bottom.
    private func flickDown(_ app: XCUIApplication, from y: CGFloat = 0.5) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func swipeFromLeftEdge(_ app: XCUIApplication, at y: CGFloat = 0.55) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func assertGone(_ element: XCUIElement, _ what: String) {
        let gone = NSPredicate(format: "exists == false")
        let result = XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: 4)
        XCTAssertEqual(result, .completed, "\(what) is still on screen")
    }

    private func dismissesFromMiddle(_ arguments: [String], marker: XCUIElement? = nil, text: String, from y: CGFloat = 0.5) {
        let app = launch(arguments)
        let element = marker ?? app.staticTexts[text]
        XCTAssertTrue(element.waitForExistence(timeout: 25), "\(text) never appeared")
        flickDown(app, from: y)
        assertGone(element, text)
    }

    func testSwapSheetDismissesFromItsMiddle() {
        let app = launch(["-stage", "market", "-open-swap"])
        let marker = app.buttons["MON → AUSD"]
        XCTAssertTrue(marker.waitForExistence(timeout: 25), "the swap sheet never appeared")
        flickDown(app)
        assertGone(marker, "the swap sheet")
    }

    func testActivityDismissesFromItsMiddle() {
        dismissesFromMiddle(["-stage", "market", "-open-activity"], text: "Activity")
    }

    func testAddFundsDismissesFromItsMiddle() {
        dismissesFromMiddle(["-stage", "market", "-open-funds"], text: "Add funds")
    }

    func testTicketDismissesFromItsMiddle() {
        let app = launch(["-stage", "market", "-open-ticket"])
        let marker = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'MAX'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 40), "the ticket never appeared")
        flickDown(app, from: 0.35)
        assertGone(marker, "the ticket")
    }

    func testHoldingSheetDismissesFromItsMiddle() {
        let app = launch(["-stage", "home", "-holdings-demo", "-open-holding"])
        let marker = app.buttons["Buy more"]
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "the holding sheet never appeared")
        // From the candle chart: its hold-to-read gesture used to keep every touch.
        let chart = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Chart for'")).firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "no chart on the holding sheet")
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        assertGone(marker, "the holding sheet")
    }

    func testHoldingOnTheChartReadsCandlesAndKeepsTheSheet() {
        let app = launch(["-stage", "home", "-holdings-demo", "-open-holding"])
        let marker = app.buttons["Buy more"]
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "the holding sheet never appeared")
        let chart = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Chart for'")).firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "no chart on the holding sheet")
        // A held finger is a reading, not a swipe: the sheet stays while it slides across and down.
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 1.6)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(marker.waitForExistence(timeout: 2), "the sheet closed while the chart was being read")
    }

    func testTheHomePageScrollsWhenTheFlickStartsOnTheTicker() {
        let app = launch(["-stage", "market"])
        let ticker = app.descendants(matching: .any)["trending-ticker"].firstMatch
        XCTAssertTrue(ticker.waitForExistence(timeout: 30), "no ticker on Home")
        let heading = app.staticTexts["Explore Markets"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let before = heading.frame.minY
        ticker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: ticker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -4)),
                   withVelocity: .fast, thenHoldForDuration: 0.3)
        XCTAssertLessThan(heading.frame.minY, before - 80, "the page did not scroll")
    }

    func testMarketPageGoesBackFromTheMiddleOfThePage() {
        let app = launch(["-stage", "market", "-open-detail"])
        let chat = app.staticTexts["Live Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "the market page never opened")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        assertGone(chat, "the market page")
    }

    func testMarketPageGoesBackFromTheLeftEdge() {
        let app = launch(["-stage", "market", "-open-detail"])
        let chat = app.staticTexts["Live Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "the market page never opened")
        swipeFromLeftEdge(app)
        assertGone(chat, "the market page")
    }
}
