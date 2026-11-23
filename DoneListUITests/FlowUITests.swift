import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()

    private enum Language: String, CaseIterable {
        case english = "en", simplified = "zh-Hans", traditional = "zh-Hant"
        var locale: String {
            switch self {
            case .english: return "en_US"
            case .simplified: return "zh_CN"
            case .traditional: return "zh_TW"
            }
        }
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    func testFirstLaunchAddContinuousEditDeleteUndoAndDraftRecovery() {
        launch()
        tap("today.compose")
        let input = app.textViews["entry.text"]
        wait(input)
        input.typeText("First win\n")
        wait(app.staticTexts["0 of 240"])
        input.typeText("Second win")
        tap("entry.save")
        wait(entry("First win"))
        tap("Second win")
        let editor = app.textViews["edit.text"]
        wait(editor)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 13) + "Edited win")
        tap("edit.save")
        tap("Edited win")
        tap("edit.delete")
        tap("entry.undo")
        wait(entry("Edited win"))

        tap("today.compose")
        app.textViews["entry.text"].typeText("Saved draft")
        wait(app.staticTexts["11 of 240"])
        launch(reset: false)
        wait(app.textViews["entry.text"])
        XCTAssertEqual(app.textViews["entry.text"].value as? String, "Saved draft")
        tap("entry.save")
        wait(entry("Saved draft"))
    }

    func testReviewHistoryAndPrivateSharing() {
        launch(["-seed"])
        tap("tab.review")
        wait(app.buttons["review.share"])
        let countCells = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "review.count.")).allElementsBoundByIndex
        XCTAssertEqual(Set(countCells.map(\.identifier)).count, 7)
        XCTAssertTrue(countCells.contains { $0.label.hasSuffix("0 done") })
        tap("review.share")
        wait(app.images["share.preview"])
        XCTAssertTrue(app.staticTexts["Entry text is hidden."].exists)
        tap("share.image")
        wait(app.staticTexts["share.requested"])
        tap("share.choose")
        let pick = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "share.pick.")).firstMatch
        wait(pick)
        pick.tap()
        tap("share.entryDone")
        wait(app.staticTexts["Selected entries appear on your card."])
        tap("share.close")
        tap("review.history")
        let search = app.textFields["history.search"]
        wait(search)
        search.tap()
        search.typeText("invoice")
        wait(entry("Sent the invoice before lunch"))
        XCTAssertFalse(entry("Watered the balcony plants").exists)
    }

    func testPresetFileBackupAndExpiredKeepsBasicRecords() {
        let backup = """
        {"version":1,
         "entries":[{"id":"2F21E346-650C-4DEA-8A01-971C8E9F4850","text":"Imported local record",
          "dayKey":"2025-04-10","createdAt":766022400,"updatedAt":766022400,"captureTimeZone":"GMT"}]}
        """
        launch(["-expired", "-seed"], environment: ["DAYNOTED_PRESET": "DL1:eyJsYXlvdXQiOiJiYXJzIn0", "DAYNOTED_BACKUP": backup])
        wait(entry("Sent the invoice before lunch"))
        tap("today.settings")
        tap("preset.paste")
        tap("preset.apply")
        tap("backup.export")
        wait(app.staticTexts["export.requested"])
        tap("backup.import")
        tap("backup.merge")
        wait(app.staticTexts["settings.status"])
        tap("backup.csv")
        wait(app.staticTexts["paywall.state"])
        XCTAssertEqual(app.staticTexts["paywall.state"].label, "Trial ended")
        tap("paywall.close")
        tap("settings.done")
        tap("tab.review")
        tap("review.history")
        let search = app.textFields["history.search"]
        search.tap()
        search.typeText("Imported local record")
        wait(entry("Imported local record"))
    }

func testNativePasteRoundTrip() {
        launch()
        tap("today.settings")
        tap("preset.copy")
        let identified = app.buttons["preset.paste"]
        if identified.waitForExistence(timeout: 4), identified.isHittable {
            identified.tap()
        } else {
            tap("Paste")
        }
        tap("preset.apply")
        wait(app.staticTexts["settings.status"])
        XCTAssertEqual(app.staticTexts["settings.status"].label, "Preset applied.")
    }

    func testFastLogRouteAndPlusReview() {
        launch(["-quick-log", "-pro"])
        wait(app.textViews["entry.text"])
        app.textViews["entry.text"].typeText("From the widget")
        tap("entry.save")
        tap("tab.review")
        tap("review.period")
        tap("This month")
        tap("review.period")
        tap("Custom range")
        tap("range.apply")
        wait(app.buttons["review.period"])
    }

    func testStoreScreenshots() {
        for language in Language.allCases {
            let line: String
            switch language {
            case .english: line = "Finished the first draft"
            case .simplified: line = "写完了第一版草稿"
            case .traditional: line = "寫完了第一版草稿"
            }
            launch(["-seed"], language: language, environment: ["DAYNOTED_COMPOSE_TEXT": line])
            wait(app.buttons["today.compose"])
            shot("store-\(language.rawValue)-01-today")

            tap("today.compose")
            let input = app.textViews["entry.text"]
            wait(input)
            XCTAssertEqual(input.value as? String, line)
            shot("store-\(language.rawValue)-02-compose")
            tap("entry.cancel")

            tap("tab.review")
            wait(app.buttons["review.share"])
            shot("store-\(language.rawValue)-03-week")

            tap("review.history")
            wait(app.textFields["history.search"])
            shot("store-\(language.rawValue)-04-history")
            tap("history.close")

            tap("review.milestoneShare")
            wait(app.images["share.preview"])
            shot("store-\(language.rawValue)-05-share")
        }
    }

    func testPaidScreenshot() {
        launch(["-paywall"], language: .simplified)
        wait(app.buttons["paywall.trial"])
        XCTAssertTrue(app.buttons["paywall.buy"].exists)
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        shot("paid-01-paywall")
    }

    private func launch(_ arguments: [String] = [], language: Language = .english, reset: Bool = true,
                        environment: [String: String] = [:]) {
        app.terminate()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language.rawValue))", "-AppleLocale", language.locale]
            + (reset ? ["-reset"] : []) + arguments
        app.launchEnvironment = environment
        app.launch()
    }

    private func entry(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "entry.", text)).firstMatch
    }

    private func wait(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)", file: file, line: line)
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let elements = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, id))
        let hasFirst = elements.firstMatch.waitForExistence(timeout: 3)
        for _ in 0..<4 {
            if let button = elements.allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled }) {
                button.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("\(hasFirst ? "Cannot tap" : "Missing") \(id)", file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
