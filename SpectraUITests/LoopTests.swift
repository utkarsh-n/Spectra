import XCTest

/// The loop end to end (SPEC.md §1, "the loop is visible everywhere"), with every sensor
/// simulated: Live → Scope and Patch, Radio → Spectrum, Spin → strip and tuner, Patch ruler →
/// Spectrum source A, Spectrum lab ← magnetometer, Live → Radio card, and "Modulate from…" on a
/// knob of another tab → a Patch Knob target.
final class LoopTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// Live Magnetometer card → Open in Scope shows its streams; → Add to Patch adds a node.
  @MainActor
  func testLiveCardOpensScopeAndAddsToPatch() {
    let app = UITest.launch(["-open", "live/magnetometer"])
    XCTAssertNotNil(UITest.element("live-card-magnetometer", in: app))
    UITest.reveal(tap: "live-magnetometer-scope", in: app)
    XCTAssertNotNil(UITest.element("scope-view", in: app), "the Scope page comes forward")
    // The scale line under the display reads "CH1 5 µT/div …" once the magnetometer streams
    // sit on the channels.
    let scale = app.descendants(matching: .any).matching(identifier: "scope-view").firstMatch
      .descendants(matching: .staticText).matching(NSPredicate(format: "label CONTAINS 'µT'")).firstMatch
    XCTAssertTrue(scale.waitForExistence(timeout: 10), "the magnetometer streams are on the scope")
    UITest.screenshot("integrated-loop-live-to-scope", in: self)
    app.terminate()

    // Add to Patch from the same card (fresh launch, so the card is where -open puts it).
    let again = UITest.launch(["-open", "live/magnetometer"])
    UITest.reveal(tap: "live-magnetometer-patch", in: again)
    addsNode(again)
  }

  @MainActor
  private func addsNode(_ app: XCUIApplication) {
    XCTAssertNotNil(UITest.hittable("tab-root-patch", in: app), "Add to Patch switches to Patch")
    let node = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'patch-node-' AND label CONTAINS[c] 'magnet'")).firstMatch
    XCTAssertTrue(node.waitForExistence(timeout: 6), "a stream node bound to the magnetometer is on the canvas")
    UITest.screenshot("integrated-loop-live-to-patch", in: self)
  }

  /// Radio carrier → Tune Spectrum here: Spectrum source A at the carrier's wavelength.
  @MainActor
  func testRadioCarrierTunesSpectrum() {
    let app = UITest.launch(["-open", "radio/antenna"])
    UITest.reveal(tap: "radio-antenna-tune-spectrum", in: app)
    UITest.screenshot("integrated-loop-radio-to-spectrum", in: self)
    XCTAssertNotNil(UITest.hittable("tab-root-spectrum", in: app), "switches to Spectrum")
    UITest.reveal(tap: "spectrum-instrument-tuner", in: app)
    XCTAssertTrue(UITest.waitFor("spectrum-tuner", toContain: "12.3 cm", in: app), UITest.describe("spectrum-tuner", in: app))
  }

  /// Spin's Larmor line is a marker on the strip and a dim line in the tuner; Spin's
  /// "Show on spectrum" tunes source A to it.
  @MainActor
  func testSpinLarmorMarkerOnStripAndTuner() {
    let app = UITest.launch(["-open", "spectrum/tuner"])
    XCTAssertTrue(UITest.waitFor("spectrum-strip", toContain: "¹H precession", in: app), UITest.describe("spectrum-strip", in: app))
    let caption = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '¹H precession'")).firstMatch
    XCTAssertTrue(caption.waitForExistence(timeout: 6), "the tuner lists the Larmor line among the app's frequencies")
    UITest.screenshot("integrated-loop-spin-marker-tuner", in: self)

    UITest.select(tab: "Spin", identifier: "tab-spin", in: app)
    UITest.reveal(tap: "spin-view-proton", in: app)
    UITest.reveal(tap: "spin-show-spectrum", in: app)
    XCTAssertNotNil(UITest.hittable("tab-root-spectrum", in: app))
    // ¹H in the (simulated) Earth field: f ≈ 2 kHz, λ ≈ 150 km.
    XCTAssertTrue(UITest.waitFor("spectrum-tuner", toContain: "km", in: app), UITest.describe("spectrum-tuner", in: app))
  }

  /// Patch Spectrum-ruler sink → Send to Spectrum retunes source A (Earth-field NMR preset).
  @MainActor
  func testPatchRulerRetunesSpectrum() {
    let app = UITest.launch(["-open", "patch/earthNMR/n4"])
    XCTAssertNotNil(UITest.hittable("patch-inspector-done", in: app), "the ruler's inspector is open")
    // -ui-testing starts paused; the graph runs while the clock plays. The transport sits
    // under the inspector sheet: close it, play, and open the ruler again.
    UITest.tap("patch-inspector-done", in: app)
    UITest.tap("transport-play", in: app)
    XCTAssertTrue(UITest.waitFor("patch-status", toContain: "RUN", in: app, timeout: 8), UITest.describe("patch-status", in: app))
    UITest.tap("patch-node-n4", in: app)
    XCTAssertNotNil(UITest.hittable("patch-inspector-done", in: app))
    let send = app.descendants(matching: .any).matching(identifier: "patch-inspector-send").firstMatch
    XCTAssertTrue(send.waitForExistence(timeout: 6))
    let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
    wait(for: [enabled], timeout: 10)
    UITest.reveal(tap: "patch-inspector-send", in: app)
    UITest.screenshot("integrated-loop-patch-ruler-to-spectrum", in: self)
    XCTAssertNotNil(UITest.hittable("tab-root-spectrum", in: app), "switches to Spectrum")
    // The ruler carries the FID's Larmor line (≈ 2 kHz in the simulated field): λ ≈ 150 km.
    UITest.reveal(tap: "spectrum-instrument-tuner", in: app)
    XCTAssertTrue(UITest.waitFor("spectrum-tuner", toContain: "km", in: app), UITest.describe("spectrum-tuner", in: app))
  }

  /// Spectroscopy lab, Earth-field mode: B₀ comes from the (simulated) magnetometer.
  @MainActor
  func testLabEarthFieldReadsMagnetometer() {
    let app = UITest.launch(["-open", "spectrum/lab/earth"])
    XCTAssertNotNil(UITest.element("spectrum-lab-earth-stage", in: app), "Earth-field stage")
    XCTAssertTrue(
      // The simulated field (≈ 45.7 µT) puts the water line near 1.94 kHz, not the 50 µT
      // stand-in's 2.13 kHz.
      UITest.waitFor("spectrum-lab-earth-stage", toContain: "Water line at 1.9", in: app, timeout: 10),
      UITest.describe("spectrum-lab-earth-stage", in: app))
    UITest.screenshot("integrated-loop-lab-earth-field", in: self)
    // Hear it in Spin hands the line to the Spin tab.
    UITest.reveal(tap: "spectrum-lab-earth-spin", in: app)
    XCTAssertNotNil(UITest.hittable("tab-root-spin", in: app), "Hear it in Spin switches to Spin")
    // Spin → Open in Lab comes back to the same lab mode (SpinEarthFieldLab conformance).
    UITest.reveal(tap: "spin-open-lab", in: app)
    XCTAssertNotNil(UITest.hittable("tab-root-spectrum", in: app), "Open in Lab switches to Spectrum")
    XCTAssertNotNil(UITest.element("spectrum-lab-earth-stage", in: app), "lands in the Earth-field lab")
  }

  /// Live Cellular & Wi-Fi → open card: Radio's Systems page on that system.
  @MainActor
  func testLiveNetworkOpensRadioCard() {
    let app = UITest.launch(["-open", "live/network"])
    UITest.reveal(tap: "live-network-open-card", in: app)
    XCTAssertNotNil(UITest.hittable("tab-root-radio", in: app), "switches to Radio")
    XCTAssertNotNil(UITest.element("radio-iphone-only", in: app), "Systems page")
    UITest.screenshot("integrated-loop-live-to-radio-card", in: self)
  }

  /// Long-press a Spin knob → "Modulate from…" → Patch adds a Knob target aimed at it.
  @MainActor
  func testKnobModulateFromAddsKnobTarget() {
    let app = UITest.launch(["-open", "spin/proton"])
    UITest.tap("dials-open", in: app)
    // With the simulated magnetometer the field is live, so the B₀ dial is hidden; B₁ is a dial.
    guard let knob = UITest.bringIntoView("knob-spin-p-b1", in: app) else {
      XCTFail("no Spin knob in the Dials sheet")
      return
    }
    knob.press(forDuration: 1.0)
    XCTAssertNotNil(UITest.hittable("tab-root-patch", in: app, timeout: 6), "Modulate from… opens Patch")
    XCTAssertNotNil(UITest.hittable("patch-inspector-done", in: app), "the new Knob target's inspector")
    let target = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '-target'")).firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 4))
    XCTAssertTrue(
      target.label.contains("Spin") || ((target.value as? String)?.contains("Spin") ?? false),
      "aimed at the Spin knob: \(target.label) \(String(describing: target.value))")
    UITest.screenshot("integrated-loop-modulate-from", in: self)
  }
}
