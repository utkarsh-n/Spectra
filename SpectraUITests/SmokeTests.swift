import XCTest

/// Smoke tests with every sensor simulated (`-fakeAll -ui-testing`): every tab opens to its
/// root; each tab's Dials, Field notes and Settings sheets open and close; every instrument,
/// page and sheet of every tab is visited. Screenshots are attached (kept on success) and
/// named `integrated-…` so they can be exported from the result bundle.
final class SmokeTests: XCTestCase {
  private let tabs: [(id: String, title: String)] = [
    ("spectrum", "Spectrum"), ("radio", "Radio"), ("live", "Live"), ("spin", "Spin"), ("patch", "Patch"),
  ]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: Chrome on every tab

  @MainActor
  func testEveryTabOpensWithItsChrome() {
    let app = UITest.launch()
    for tab in tabs {
      UITest.select(tab: tab.title, identifier: "tab-\(tab.id)", in: app)
      XCTAssertNotNil(UITest.hittable("tab-root-\(tab.id)", in: app), "\(tab.title) root is visible")
      XCTAssertNotNil(UITest.hittable("spectrum-strip", in: app), "\(tab.title) shows the Spectrum strip")
      XCTAssertNotNil(UITest.hittable("dials-open", in: app), "\(tab.title) has the Dials button")
      UITest.screenshot("integrated-tab-\(tab.id)", in: self)
    }
  }

  @MainActor
  func testSheetsOpenAndCloseOnEveryTab() {
    let app = UITest.launch()
    for tab in tabs {
      UITest.select(tab: tab.title, identifier: "tab-\(tab.id)", in: app)
      XCTAssertNotNil(UITest.hittable("tab-root-\(tab.id)", in: app))

      UITest.tap("dials-open", in: app)
      XCTAssertNotNil(UITest.hittable("dials-done", in: app), "\(tab.title) dials sheet")
      UITest.screenshot("integrated-sheet-dials-\(tab.id)", in: self)
      UITest.tap("dials-done", in: app)

      UITest.tap("field-notes-open", in: app)
      XCTAssertNotNil(UITest.hittable("field-notes-done", in: app), "\(tab.title) field notes")
      UITest.screenshot("integrated-sheet-notes-\(tab.id)", in: self)
      UITest.tap("field-notes-done", in: app)

      UITest.tap("settings-open", in: app)
      XCTAssertNotNil(UITest.hittable("settings-done", in: app), "\(tab.title) settings")
      if tab.id == "spectrum" { UITest.screenshot("integrated-sheet-settings", in: self) }
      UITest.tap("settings-done", in: app)
    }
  }

  @MainActor
  func testSettingsShowsFeedbackAndCensus() {
    let app = UITest.launch()
    UITest.tap("settings-open", in: app)
    XCTAssertNotNil(UITest.hittable("settings-haptics", in: app))
    XCTAssertNotNil(UITest.hittable("settings-sound", in: app))
    let census = UITest.reveal("settings-census", in: app)
    XCTAssertNotNil(census, "Sensor census row")
    census?.tap()
    // Settings → Sensor census is the live slice's census (capability flags included).
    XCTAssertNotNil(UITest.hittable("live-census-magnetometer", in: app, timeout: 6))
    XCTAssertNotNil(UITest.element("live-census-run-magnetometer", in: app))
    UITest.screenshot("integrated-sheet-settings-census", in: self)
  }

  @MainActor
  func testTransportPlaysAndSteps() {
    let app = UITest.launch(["-open", "spectrum"])
    let clock = UITest.hittable("transport-clock", in: app)
    XCTAssertNotNil(clock)
    XCTAssertTrue(clock?.label.hasPrefix("Simulation paused") ?? false, "-ui-testing starts paused")
    UITest.tap("transport-step", in: app)
    XCTAssertEqual(UITest.hittable("transport-clock", in: app)?.label, "Simulation paused, 00:00.01")
    UITest.tap("transport-play", in: app)
    let running = NSPredicate(format: "label BEGINSWITH 'Simulation running'")
    expectation(for: running, evaluatedWith: app.descendants(matching: .any).matching(identifier: "transport-clock").firstMatch)
    waitForExpectations(timeout: 5)
  }

  // MARK: Every instrument and page

  @MainActor
  func testSpectrumInstrumentsPagesAndFullScreen() {
    let app = UITest.launch(["-open", "spectrum/scope"])
    let instruments: [(id: String, stage: String)] = [
      ("scope", "spectrum-wave-stage"), ("tuner", "spectrum-tuner"), ("bench", "spectrum-bench-stage"),
      ("decompose", "spectrum-decompose-stage"), ("lab", "spectrum-lab-stage"),
    ]
    for item in instruments {
      UITest.reveal(tap: "spectrum-instrument-\(item.id)", in: app)
      XCTAssertNotNil(UITest.element(item.stage, in: app), "\(item.id) shows its stage")
      UITest.screenshot("integrated-spectrum-\(item.id)", in: self)
    }
    // Decompose: all four pages.
    UITest.reveal(tap: "spectrum-instrument-decompose", in: app)
    for page in ["polarization", "probe", "fourier", "phase"] {
      UITest.reveal(tap: "spectrum-decompose-\(page)", in: app)
      if page == "phase" {
        XCTAssertNotNil(UITest.element("spectrum-phase-cube", in: app, timeout: 15), "Φ cube")
        XCTAssertNotNil(UITest.element("spectrum-phase-marginals", in: app, timeout: 15), "marginals strip")
      } else {
        XCTAssertNotNil(UITest.element("spectrum-decompose-stage", in: app))
      }
      UITest.screenshot("integrated-spectrum-decompose-\(page)", in: self)
    }
    // Lab: every sample.
    UITest.reveal(tap: "spectrum-instrument-lab", in: app)
    for sample in ["hydrogen", "co2", "water", "chlorophyll", "nmr"] {
      UITest.reveal(tap: "spectrum-lab-sample-\(sample)", in: app)
      XCTAssertNotNil(UITest.element("spectrum-lab-stage", in: app))
    }
    UITest.screenshot("integrated-spectrum-lab-nmr", in: self)
    // Full screen and back.
    UITest.reveal(tap: "spectrum-fullscreen", in: app)
    XCTAssertNotNil(UITest.hittable("fullscreen-close", in: app), "full screen opens")
    UITest.screenshot("integrated-spectrum-fullscreen", in: self)
    UITest.tap("fullscreen-close", in: app)
    XCTAssertNotNil(UITest.hittable("tab-root-spectrum", in: app))
  }

  @MainActor
  func testRadioPages() {
    let app = UITest.launch(["-open", "radio/antenna"])
    let pages: [(title: String, probe: String)] = [
      ("Antenna", "radio-style-dipole"), ("Systems", "radio-iphone-only"), ("Fourier", "radio-change-system"),
      ("Link", "radio-use-antenna-gain"),
    ]
    for page in pages {
      UITest.selectSegment(page.title, of: "radio-page", in: app)
      XCTAssertNotNil(UITest.element(page.probe, in: app), "Radio \(page.title) shows \(page.probe)")
      UITest.screenshot("integrated-radio-\(page.title.lowercased())", in: self)
    }
    // Antenna styles (a sample across the families).
    UITest.selectSegment("Antenna", of: "radio-page", in: app)
    for style in ["yagi", "dish", "phasedArray", "pifa"] {
      UITest.reveal(tap: "radio-style-\(style)", in: app)
      XCTAssertNotNil(UITest.element("radio-cut-plot", in: app))
    }
    UITest.screenshot("integrated-radio-antenna-pifa", in: self)
  }

  @MainActor
  func testLiveCardsScopePageAndSheets() {
    let app = UITest.launch(["-open", "live"])
    let cards = [
      "antennas", "bluetooth", "network", "gnss", "magnetometer", "microphone", "light", "air", "charging", "motion",
      "uwb", "nfc",
    ]
    for card in cards {
      XCTAssertNotNil(UITest.element("live-card-\(card)", in: app, timeout: 10), "Live card \(card)")
    }
    // Scroll the whole Sensors page in the gutter, so every card comes on screen (and starts
    // its simulated source), until the census card at the end is reachable.
    var swipes = 0
    while UITest.hittable("live-census-open", in: app, timeout: 0.3) == nil, swipes < 40 {
      UITest.scrollPage(app, up: true, distance: 0.45)
      swipes += 1
      if swipes % 4 == 0 { UITest.screenshot("integrated-live-sensors-\(swipes / 4)", in: self) }
    }
    XCTAssertGreaterThan(swipes, 5, "the Sensors page scrolls through its cards")
    // Census sheet from the card at the end of the page.
    UITest.reveal(tap: "live-census-open", in: app)
    XCTAssertNotNil(UITest.hittable("live-census-done", in: app), "census sheet")
    UITest.screenshot("integrated-live-census", in: self)
    UITest.tap("live-census-done", in: app)

    // Scope page: every mode, the channel, math and notes sheets.
    UITest.selectSegment("Scope", of: "live-page", in: app)
    XCTAssertNotNil(UITest.element("scope-view", in: app), "Scope page")
    XCTAssertNil(UITest.hittable("transport-play", in: app, timeout: 1), "no Live transport over the Scope")
    for mode in ["yt", "roll", "xy", "fft", "spectrogram", "wignerVille", "pseudoWigner"] {
      UITest.reveal(tap: "scope-mode-\(mode)", in: app)
      XCTAssertNotNil(UITest.element("scope-display", in: app))
      UITest.screenshot("integrated-live-scope-\(mode)", in: self)
    }
    UITest.reveal(tap: "scope-mode-yt", in: app)
    UITest.reveal(tap: "scope-channel-1", in: app)
    XCTAssertNotNil(UITest.hittable("dials-done", in: app), "channel sheet")
    UITest.screenshot("integrated-live-scope-channel-sheet", in: self)
    UITest.tap("dials-done", in: app)
    UITest.reveal(tap: "scope-math", in: app)
    XCTAssertNotNil(UITest.hittable("dials-done", in: app), "math sheet")
    UITest.screenshot("integrated-live-scope-math-sheet", in: self)
    UITest.tap("dials-done", in: app)
    UITest.reveal(tap: "scope-notes", in: app)
    XCTAssertNotNil(UITest.hittable("field-notes-done", in: app), "scope notes")
    UITest.tap("field-notes-done", in: app)
    // The Dials sheet on the Scope page leads with the probes.
    UITest.tap("dials-open", in: app)
    XCTAssertNotNil(UITest.element("scope-preset-magnetic", in: app, timeout: 4) ?? UITest.element("live-toggle-magnetometer", in: app))
    UITest.screenshot("integrated-live-scope-dials", in: self)
    UITest.tap("dials-done", in: app)
  }

  @MainActor
  func testSpinViews() {
    let app = UITest.launch(["-open", "spin/gyroscope"])
    for view in ["gyroscope", "proton", "electron", "compare"] {
      UITest.reveal(tap: "spin-view-\(view)", in: app)
      XCTAssertNotNil(UITest.element("spin-scene", in: app), "\(view) scene")
      UITest.screenshot("integrated-spin-\(view)", in: self)
    }
  }

  @MainActor
  func testPatchCanvasPresetsPaletteAndInspector() {
    let app = UITest.launch(["-open", "patch/earthNMR"])
    XCTAssertNotNil(UITest.element("patch-canvas", in: app))
    XCTAssertNotNil(UITest.element("patch-node-n1", in: app))
    UITest.screenshot("integrated-patch-canvas", in: self)

    UITest.tap("patch-presets", in: app)
    XCTAssertNotNil(UITest.hittable("patch-presets-done", in: app), "presets sheet")
    UITest.screenshot("integrated-patch-presets", in: self)
    UITest.tap("patch-presets-done", in: app)

    UITest.tap("patch-add", in: app)
    XCTAssertNotNil(UITest.hittable("patch-palette-cancel", in: app), "palette sheet")
    UITest.screenshot("integrated-patch-palette", in: self)
    UITest.tap("patch-palette-cancel", in: app)

    UITest.tap("patch-node-n2", in: app)
    XCTAssertNotNil(UITest.hittable("patch-inspector-done", in: app), "inspector")
    UITest.screenshot("integrated-patch-inspector", in: self)
    UITest.tap("patch-inspector-done", in: app)
  }
}
