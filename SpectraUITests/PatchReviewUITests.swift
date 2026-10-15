import XCTest

/// TEMPORARY (patch review 3): screenshots and flows of the Patch tab. Deleted after the run.
@MainActor
final class PatchReviewUITests: XCTestCase {
  static let shots = "/private/tmp/claude-501/-Users-utkarsh-Documents-AI-Stuff/dff7e263-35a4-4ca5-aaa9-0ae44a146fe2/scratchpad/shots"

  override func setUp() {
    continueAfterFailure = true
    try? FileManager.default.createDirectory(atPath: Self.shots, withIntermediateDirectories: true)
  }

  func shot(_ name: String, wait: TimeInterval = 1.5) {
    RunLoop.current.run(until: Date().addingTimeInterval(wait))
    let data = XCUIScreen.main.screenshot().pngRepresentation
    try? data.write(to: URL(fileURLWithPath: "\(Self.shots)/\(name).png"))
  }

  func element(_ id: String, _ app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for e in app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex where e.exists && e.isHittable {
        return e
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while Date() < deadline
    return nil
  }

  func tap(_ id: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    guard let e = element(id, app) else {
      XCTFail("no \(id)", file: file, line: line)
      return
    }
    e.tap()
  }

  func reveal(_ id: String, _ app: XCUIApplication, in scroll: String) -> XCUIElement? {
    for _ in 0..<10 {
      if let e = element(id, app, timeout: 0.6) { return e }
      element(scroll, app, timeout: 1)?.swipeUp(velocity: .slow)
    }
    return element(id, app, timeout: 1)
  }

  /// The clock plays (no -ui-testing), as on the phone.
  func launch(_ extra: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-fakeAll"] + extra
    app.launch()
    return app
  }

  func testA_Presets() {
    let names = [
      "earthNMR": "patch-earth-nmr", "voiceAM": "patch-voice-am", "voiceFM": "patch-voice-fm", "wifiOFDM": "patch-wifi-ofdm",
      "bleLive": "patch-ble-live", "mainsHum": "patch-mains-hum", "gyroArray": "patch-gyro-array",
      "lightSpectrum": "patch-light-spectrum",
    ]
    for (preset, name) in names.sorted(by: { $0.key < $1.key }) {
      let app = launch(["-open", "patch/\(preset)"])
      XCTAssertNotNil(element("patch-canvas", app), preset)
      shot(name, wait: 6)
      app.terminate()
    }
  }

  func testB_Inspectors() {
    let list: [(String, String)] = [
      ("wifiOFDM/n4", "patch-inspector-channel"), ("earthNMR/n7", "patch-inspector-wigner"),
      ("mainsHum/n3", "patch-inspector-scope"), ("voiceFM/n2/dials", "patch-inspector-dials"),
      ("earthNMR/n4", "patch-inspector-ruler"), ("earthNMR/n5", "patch-inspector-fft"),
      ("gyroArray/n1/live", "patch-inspector-gyroscope"), ("earthNMR/n8/cables", "patch-inspector-marginal"),
    ]
    for (path, name) in list {
      let app = launch(["-open", "patch/\(path)"])
      XCTAssertNotNil(element("patch-inspector-done", app), path)
      shot(name, wait: 6)
      if path == "mainsHum/n3" {
        // The Scope node's own streams appear in its inspector (the sheet opened before they
        // existed).
        XCTAssertFalse(
          app.staticTexts["Cable signals into CH1–CH4; each becomes a stream on the scope bus named after this node."].exists,
          "the Scope node's inspector shows its streams")
      }
      if path == "earthNMR/n4" {
        // Send to Spectrum becomes available once the ruler has a value.
        if let send = reveal("patch-inspector-send", app, in: "patch-inspector-scroll") {
          XCTAssertTrue(send.isEnabled, "Send to Spectrum enabled once the ruler has a value")
          send.tap()
          shot("flow-ruler-sent", wait: 2)
          XCTAssertNil(element("patch-canvas", app, timeout: 2), "Send to Spectrum left the Patch tab")
        } else {
          XCTFail("no Send to Spectrum")
        }
      }
      app.terminate()
    }
  }

  func testC_SheetsAndFlows() {
    let app = launch(["-open", "patch/earthNMR"])
    XCTAssertNotNil(element("patch-canvas", app))
    // Dials sheet: View, Presets, Patch panels; Reset dials / Reset alignment pinned.
    tap("dials-open", app)
    XCTAssertNotNil(element("dials-reset", app), "Reset dials pinned")
    XCTAssertNotNil(element("dials-reset-alignment", app), "Reset alignment pinned")
    shot("patch-dials-sheet")
    if let zoom = element("patch-dials-zoom", app) {
      zoom.adjust(toNormalizedSliderPosition: 0.6)
    }
    tap("dials-reset", app)
    tap("dials-reset-alignment", app)
    tap("dials-done", app)
    // Field notes and their sources.
    tap("field-notes-open", app)
    shot("patch-field-notes")
    for _ in 0..<6 { element("field-notes-scroll", app, timeout: 2)?.swipeUp() }
    shot("patch-field-notes-sources")
    tap("field-notes-done", app)
    // Palette: add an Oscillator; it lands clear of the other cards.
    tap("patch-add", app)
    shot("patch-palette", wait: 1)
    tap("patch-palette-oscillator", app)
    XCTAssertNotNil(element("patch-node-header-n10", app), "the Oscillator was added")
    shot("patch-added-node")
    tap("patch-fit", app)
    // Rename it.
    tap("patch-node-header-n10", app)
    if let field = element("patch-inspector-title", app) {
      field.tap()
      field.typeText("Test tone\n")
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      XCTAssertTrue(app.navigationBars.staticTexts["Test tone"].exists, "renamed")
    }
    // Delete it through the inspector.
    if let delete = reveal("patch-inspector-delete", app, in: "patch-inspector-scroll") {
      delete.tap()
      app.buttons["Delete node"].firstMatch.tap()
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      XCTAssertNil(element("patch-node-header-n10", app, timeout: 2), "the node was deleted")
    } else {
      XCTFail("no Delete")
    }
    // Presets sheet.
    tap("patch-presets", app)
    shot("patch-presets", wait: 1)
    tap("patch-presets-done", app)
    // Inspector of the Spin FID, then Open in Scope.
    tap("patch-node-header-n2", app)
    XCTAssertNotNil(element("patch-inspector-done", app))
    if let open = reveal("patch-inspector-open-scope", app, in: "patch-inspector-scroll") {
      open.tap()
      shot("patch-open-in-scope", wait: 3)
    } else {
      XCTFail("no Open in Scope")
    }
  }

  func testD_GyroscopeTimeChip() {
    let app = launch(["-open", "patch/gyroArray/n1/dials"])
    guard let slider = reveal("knob-patch-n1-time-slider", app, in: "patch-inspector-scroll") else {
      XCTFail("no Time slider")
      return
    }
    slider.adjust(toNormalizedSliderPosition: 0.436)
    tap("patch-inspector-done", app)
    shot("patch-gyro-slowed", wait: 3)
    let chip = element("transport-time-mapping", app)
    XCTAssertTrue(chip?.label.localizedCaseInsensitiveContains("slow") ?? false, chip?.label ?? "no chip")
  }

  func testE_ConnectMenuAndUnplug() {
    let app = launch(["-open", "patch/voiceFM/n4/cables"])
    // Unplug the Channel's signal input, then connect it again from the menu.
    tap("patch-unplug-n4-signal", app)
    tap("patch-connect-n4-signal", app)
    shot("patch-inspector-connect-menu", wait: 1)
    let item = app.buttons["Modulator · Signal"].firstMatch
    if item.waitForExistence(timeout: 4) {
      item.tap()
      XCTAssertNotNil(element("patch-unplug-n4-signal", app, timeout: 4), "re-plugged from the menu")
    } else {
      XCTFail("no Modulator · Signal in the Connect… menu")
    }
  }

  func testF_ClearAndEmptyState() {
    let app = launch(["-open", "patch/mainsHum"])
    tap("dials-open", app)
    if let clear = reveal("patch-dials-clear", app, in: "dials-scroll") {
      clear.tap()
      app.buttons["Clear the canvas"].firstMatch.tap()
    }
    tap("dials-done", app)
    XCTAssertNotNil(element("patch-empty-add", app), "the empty state")
    shot("patch-empty")
    tap("patch-empty-presets", app)
    tap("patch-preset-bleLive", app)
    XCTAssertNotNil(element("patch-node-header-n1", app), "a preset loads from the empty state")
  }

  func testG_AccessibilityXL() {
    let xl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    var app = launch(["-open", "patch/earthNMR"] + xl)
    shot("patch-xl-canvas", wait: 5)
    app.terminate()
    app = launch(["-open", "patch/voiceFM/n2/dials"] + xl)
    shot("patch-xl-inspector", wait: 5)
    app.terminate()
    app = launch(["-open", "patch/earthNMR/palette"] + xl)
    shot("patch-xl-palette", wait: 4)
    app.terminate()
  }
}
