import XCTest

/// Shared UI-test helpers (Orbitals' `launchPausedApp`, `requireHittable`, `wait`).
/// Elements are found only by accessibility identifier or exact label.
@MainActor
enum UITest {
  /// Launches Spectra with every sensor simulated, fresh defaults and a paused clock.
  static func launch(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-fakeAll", "-ui-testing"] + extra
    app.launch()
    return app
  }

  /// The first hittable element with `identifier` (TabView keeps other tabs' copies of the
  /// top bar in the hierarchy, so identifiers can repeat), waiting up to `timeout`.
  static func hittable(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 8) -> XCUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let query = app.descendants(matching: .any).matching(identifier: identifier)
      for element in query.allElementsBoundByIndex where element.exists && element.isHittable {
        return element
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while Date() < deadline
    return nil
  }

  /// Taps the hittable element with `identifier`, failing the test if there is none.
  static func tap(
    _ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 8, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let element = hittable(identifier, in: app, timeout: timeout) else {
      XCTFail("No hittable element \(identifier)", file: file, line: line)
      return
    }
    element.tap()
  }

  /// Swipes up (at most `swipes` times) until the element with `identifier` is hittable.
  static func reveal(_ identifier: String, in app: XCUIApplication, swipes: Int = 8) -> XCUIElement? {
    for _ in 0..<swipes {
      if let element = hittable(identifier, in: app, timeout: 0.5) { return element }
      app.swipeUp()
    }
    return hittable(identifier, in: app, timeout: 1)
  }

  /// Selects a tab: by its tab-bar identifier when the system exposes it, else by its label.
  static func select(tab title: String, identifier: String, in app: XCUIApplication) {
    if let button = hittable(identifier, in: app, timeout: 1) {
      button.tap()
      return
    }
    let byLabel = app.tabBars.buttons[title]
    if byLabel.waitForExistence(timeout: 4) {
      byLabel.tap()
    } else {
      app.buttons[title].firstMatch.tap()
    }
  }

  /// The first element with `identifier` (hittable or not), waiting up to `timeout`.
  static func element(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 8) -> XCUIElement? {
    let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    return element.waitForExistence(timeout: timeout) ? element : nil
  }

  /// Scrolls the page by dragging in the left gutter (x ≈ 8 pt), where no tuner, knob or 3D
  /// scene takes the drag: `up` moves the content up (reveals what is below).
  static func scrollPage(_ app: XCUIApplication, up: Bool = true, distance: CGFloat = 0.4) {
    let from = up ? 0.78 : 0.30
    let to = up ? from - distance : from + distance
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: from))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: to))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.15)
  }

  /// Brings the element with `identifier` on screen: horizontal chip rows are dragged along
  /// the element's row, pages are scrolled in the gutter (down first, then back up).
  /// Returns the hittable element, or nil.
  static func bringIntoView(_ identifier: String, in app: XCUIApplication, attempts: Int = 14) -> XCUIElement? {
    guard let element = element(identifier, in: app) else { return nil }
    let size = app.frame.size
    // The band of the screen not covered by the top bar, strip, transport and tab bar.
    let top: CGFloat = 200
    let bottom = size.height - 190
    for _ in 0..<attempts {
      // Hittable and clear of the floating transport and tab bar.
      if let hit = hittable(identifier, in: app, timeout: 0.4), hit.frame.midY < bottom + 30 { return hit }
      let f = element.frame
      if f.midY > top, f.midY < bottom, f.minX >= size.width - 24 || f.maxX <= 24 {
        // On screen vertically but off to one side: drag that row horizontally.
        let y = f.midY / size.height
        let right = f.minX >= size.width - 24
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.85 : 0.15, dy: y))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.3 : 0.7, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.15)
      } else if f.midY >= bottom - 40 {
        let far = f.midY - bottom
        scrollPage(app, up: true, distance: far > size.height ? 0.5 : max(0.12, min(0.45, (far + 160) / size.height)))
      } else if f.midY <= top + 40 {
        let far = top - f.midY
        scrollPage(app, up: false, distance: far > size.height ? 0.5 : max(0.12, min(0.45, (far + 160) / size.height)))
      } else {
        scrollPage(app, up: true, distance: 0.12)
      }
    }
    return hittable(identifier, in: app, timeout: 1)
  }

  /// `bringIntoView` then tap, failing the test if the element never becomes hittable.
  static func reveal(
    tap identifier: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let element = bringIntoView(identifier, in: app) else {
      XCTFail("Could not bring \(identifier) into view", file: file, line: line)
      return
    }
    element.tap()
  }

  /// Selects `segment` of the segmented page picker `identifier` (`radio-page`, `live-page`).
  static func selectSegment(
    _ segment: String, of identifier: String, in app: XCUIApplication, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let picker = app.segmentedControls.matching(identifier: identifier).firstMatch
    if !picker.waitForExistence(timeout: 6) || !picker.isHittable {
      for _ in 0..<6 where !(picker.exists && picker.isHittable) { scrollPage(app, up: false, distance: 0.5) }
    }
    let button = picker.buttons[segment]
    guard button.waitForExistence(timeout: 4) else {
      XCTFail("No segment \(segment) in \(identifier)", file: file, line: line)
      return
    }
    button.tap()
  }

  /// Waits until the element's label or value contains `text`.
  static func waitFor(
    _ identifier: String, toContain text: String, in app: XCUIApplication, timeout: TimeInterval = 8
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let query = app.descendants(matching: .any).matching(identifier: identifier)
      for e in query.allElementsBoundByIndex where e.exists {
        if e.label.contains(text) || ((e.value as? String)?.contains(text) ?? false) { return true }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while Date() < deadline
    return false
  }

  /// The label and value of every element with `identifier` (for failure messages).
  static func describe(_ identifier: String, in app: XCUIApplication) -> String {
    app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
      .map { "\($0.label) | \(($0.value as? String) ?? "")" }.joined(separator: " ;; ")
  }

  /// Attaches a screenshot that is kept even when the test passes.
  static func screenshot(_ name: String, in test: XCTestCase) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }
}
