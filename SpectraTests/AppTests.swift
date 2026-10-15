import XCTest
import simd

@testable import Spectra

/// Foundation tests: the timestamped ring, the stream registry, the marker union and the
/// cross-tab actions, settings persistence, knob mapping, time mapping and the clock, the
/// camera, the render buffer layout, the simulated sensors, and the stub physics oracles.
@MainActor
final class AppTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
    suiteNames.removeAll()
    super.tearDown()
  }

  private func makeDefaults() -> UserDefaults {
    let name = "Spectra.tests.\(UUID().uuidString)"
    suiteNames.append(name)
    return UserDefaults(suiteName: name)!
  }

  private func makeApp(_ arguments: [String] = ["-ui-testing"]) -> AppModel {
    AppModel(launch: LaunchOptions(arguments: ["Spectra"] + arguments), defaults: makeDefaults())
  }

  // MARK: TimestampedRing

  func testRingKeepsNewestInOrderAtCapacity() {
    let ring = TimestampedRing<Float>(capacity: 5)
    for i in 0..<8 { ring.append(Float(i), time: Double(i)) }
    let all = ring.snapshot()
    XCTAssertEqual(ring.capacity, 5)
    XCTAssertEqual(ring.count, 5)
    XCTAssertEqual(ring.totalAppended, 8)
    XCTAssertEqual(all.values, [3, 4, 5, 6, 7])
    XCTAssertEqual(all.times, [3, 4, 5, 6, 7])
    XCTAssertEqual(ring.latest?.value, 7)
    XCTAssertEqual(ring.latest?.time, 7)
  }

  func testRingSnapshotSinceAndLast() {
    let ring = TimestampedRing<Float>(capacity: 6)
    for i in 0..<10 { ring.append(Float(i) * 10, time: Double(i)) }
    XCTAssertEqual(ring.snapshot(since: 6.5).values, [70, 80, 90])
    XCTAssertEqual(ring.snapshot(since: 7).times, [8, 9], "since is strictly after")
    XCTAssertTrue(ring.snapshot(since: 9).isEmpty)
    XCTAssertEqual(ring.snapshot(since: -1).values, [40, 50, 60, 70, 80, 90])
    XCTAssertEqual(ring.snapshot(last: 2).values, [80, 90])
    XCTAssertEqual(ring.snapshot(last: 99).count, 6)
    ring.clear()
    XCTAssertEqual(ring.count, 0)
    XCTAssertNil(ring.latest)
  }

  func testRingUniformBlockAndMeasuredRate() {
    let ring = TimestampedRing<Float>(capacity: 1000)
    ring.append(contentsOf: [Float](repeating: 0, count: 500), start: 100, interval: 0.01)
    let snap = ring.snapshot()
    XCTAssertEqual(snap.count, 500)
    XCTAssertEqual(snap.times[1] - snap.times[0], 0.01, accuracy: 1e-12)
    XCTAssertEqual(snap.measuredRate ?? 0, 100, accuracy: 1e-6)
    XCTAssertEqual(ring.measuredRate(window: 2) ?? 0, 100, accuracy: 1e-6)
    ring.append(contentsOf: [1, 2, 3], times: [105, 105.5, 106])
    XCTAssertEqual(ring.latest?.value, 3)
  }

  func testRingIsSafeUnderConcurrentWriters() {
    let ring = TimestampedRing<Float>(capacity: 4096)
    Self.hammer(ring, workers: 8, each: 1000)
    XCTAssertEqual(ring.totalAppended, 8000)
    XCTAssertEqual(ring.count, 4096)
  }

  /// Writes from several threads at once (nonisolated, so the closure is not main-actor bound).
  nonisolated private static func hammer(_ ring: TimestampedRing<Float>, workers: Int, each: Int) {
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
      for i in 0..<each { ring.append(Float(worker), time: Double(i)) }
    }
  }

  func testStreamDefaultCapacities() {
    XCTAssertEqual(SignalStream.defaultCapacity(rate: 100), 3000, "30 s at 100 Hz")
    XCTAssertEqual(SignalStream.defaultCapacity(rate: 48_000), 96_000, "2 s of audio")
    XCTAssertEqual(SignalStream.defaultCapacity(rate: 0), 4096, "irregular streams keep 4096 events")
    let s = SignalStream(id: "ble.x.rssi", label: "x", unit: "dBm", nominalRate: 0, provenance: .sim, group: StreamGroup.bluetooth)
    XCTAssertTrue(s.isIrregular)
  }

  // MARK: StreamRegistry

  func testRegistryRegisterReplaceUnregisterAndGroups() {
    let registry = StreamRegistry()
    func make(_ id: String, _ group: String) -> SignalStream {
      SignalStream(id: StreamID(id), label: id, unit: "u", nominalRate: 10, provenance: .sim, group: group)
    }
    let spin = make("spin.fid", StreamGroup.spin)
    let magX = make("mag.x", StreamGroup.magnetometer)
    let magN = make("mag.norm", StreamGroup.magnetometer)
    registry.register(spin)
    registry.register([magX, magN])
    XCTAssertEqual(registry.streams.map(\.id.rawValue), ["mag.norm", "mag.x", "spin.fid"], "group order, then id")
    XCTAssertEqual(registry.groups.map(\.name), [StreamGroup.magnetometer, StreamGroup.spin])

    let newer = make("mag.x", StreamGroup.magnetometer)
    registry.register(newer)
    XCTAssertTrue(registry.stream("mag.x") === newer, "same id replaces")
    registry.unregister(magX)
    XCTAssertTrue(registry.stream("mag.x") === newer, "unregistering the old instance keeps the newer one")

    registry.unregister(prefix: "mag.")
    XCTAssertEqual(registry.streams.map(\.id.rawValue), ["spin.fid"])
    registry.unregister(StreamID("spin.fid"))
    XCTAssertTrue(registry.streams.isEmpty)
  }

  // MARK: Markers and cross-tab actions

  func testMarkerUnionDeduplicatesAndSortsByWavelength() {
    let a = SpectrumMarker(id: "a", label: "A", lambda: 1, provenance: .model, tab: .radio)
    let a2 = SpectrumMarker(id: "a", label: "A again", lambda: 5, provenance: .live, tab: .live)
    let b = SpectrumMarker(id: "b", label: "B", lambda: 500e-9, provenance: .model, tab: .spectrum)
    let bad = SpectrumMarker(id: "c", label: "C", frequency: 0, provenance: .model, tab: .spin)
    let union = AppModel.union([[a, bad], [a2, b]])
    XCTAssertEqual(union.map(\.id), ["b", "a"])
    XCTAssertEqual(union.last?.label, "A", "first wins")
  }

  func testAppMarkersCollectEveryTab() {
    let app = makeApp()
    let ids = Set(app.markers.map(\.id))
    XCTAssertTrue(ids.isSuperset(of: ["spectrum.A", "radio.carrier", "spin.larmor"]))
    XCTAssertEqual(app.markers.map(\.lambda), app.markers.map(\.lambda).sorted())
  }

  func testSendToSpectrumTunesSwitchesAndToasts() {
    let app = makeApp()
    app.selectedTab = .radio
    app.sendToSpectrum(lambda: 0.1229, label: "BLE")
    XCTAssertEqual(app.spectrum.sourceALambda, 0.1229, accuracy: 1e-15)
    XCTAssertEqual(app.selectedTab, .spectrum)
    XCTAssertNotNil(app.toast)
    XCTAssertEqual(app.markers.first { $0.id == "spectrum.A" }?.lambda ?? 0, 0.1229, accuracy: 1e-15)
    app.sendToSpectrum(lambda: .nan, label: "nothing")
    XCTAssertEqual(app.spectrum.sourceALambda, 0.1229, accuracy: 1e-15, "invalid wavelengths are refused")
  }

  func testFocusJumpsToTheMarkersTab() {
    let app = makeApp(["-ui-testing", "-open", "patch"])
    XCTAssertEqual(app.selectedTab, .patch)
    let larmor = app.markers.first { $0.id == "spin.larmor" }!
    app.focus(larmor)
    XCTAssertEqual(app.selectedTab, .spin)
    XCTAssertEqual(app.focusedMarker?.id, "spin.larmor")
  }

  func testUITestingStartsPaused() {
    XCTAssertFalse(makeApp().clock.playing)
  }

  // MARK: Settings

  func testSettingsRoundTripAndTolerantDecoding() throws {
    var s = AppSettings()
    s.soundOn = true
    s.hapticStrength = 0.4
    s.continuousHum = true
    s.powerUnit = .watts
    s.disabledSensors = [.microphone, .location]
    s.simulation = .always
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), s)

    let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"soundOn":true,"hapticStrength":3}"#.utf8))
    XCTAssertTrue(partial.soundOn)
    XCTAssertEqual(partial.hapticStrength, 1, "strength is clamped")
    XCTAssertTrue(partial.hapticsOn, "missing keys keep their defaults")
    XCTAssertEqual(partial.powerUnit, .dBm)
  }

  func testJSONStoreDebouncesAndFlushes() async throws {
    let defaults = makeDefaults()
    let store = JSONStore<AppSettings>(key: AppSettings.storageKey, defaults: defaults, delay: .milliseconds(50))
    var s = AppSettings()
    s.soundOn = true
    store.schedule(s)
    XCTAssertNil(defaults.data(forKey: AppSettings.storageKey), "not written before the debounce")
    XCTAssertTrue(store.hasPending)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(store.load(), s)
    s.soundOn = false
    store.schedule(s)
    store.flush()
    XCTAssertEqual(store.load(), s)
    XCTAssertFalse(store.hasPending)
  }

  func testAppModelPersistsSettings() async throws {
    let defaults = makeDefaults()
    let app = AppModel(launch: LaunchOptions(arguments: ["Spectra"]), defaults: defaults)
    app.settings.hapticStrength = 0.5
    app.save()
    let again = AppModel(launch: LaunchOptions(arguments: ["Spectra"]), defaults: defaults)
    XCTAssertEqual(again.settings.hapticStrength, 0.5)
  }

  // MARK: Knobs

  func testKnobLogMappingRoundTrips() {
    let scale = KnobScale(range: 1e-13...1e8, logarithmic: true)
    XCTAssertEqual(scale.position(of: 550e-9), (log10(550e-9) + 13) / 21, accuracy: 1e-12)
    XCTAssertEqual(scale.value(at: 0.5), pow(10, -2.5), accuracy: 1e-15)
    for p in stride(from: 0.0, through: 1.0, by: 0.05) {
      let v = scale.value(at: p)
      XCTAssertEqual(scale.position(of: v), p, accuracy: 1e-12)
    }
    XCTAssertEqual(scale.position(of: 1e20), 1, "clamped")
    XCTAssertEqual(scale.position(of: .nan), 0)
    XCTAssertFalse(KnobScale(range: 0...1, logarithmic: true).logarithmic, "log needs a positive lower bound")
  }

  func testKnobStepOriginAndModulation() {
    let stepped = KnobScale(range: 0...10, step: 2)
    XCTAssertEqual(stepped.value(at: 0.33), 4)
    let bipolar = KnobScale(range: -1...3, origin: 0)
    XCTAssertEqual(bipolar.originPosition, 0.25, accuracy: 1e-12)
    let log = KnobScale(range: 1...1000, logarithmic: true)
    // Modulation acts in position space: +1/3 of travel on a 3-decade knob is ×10.
    XCTAssertEqual(log.modulated(base: 10, depth: 0.5, cv: 2.0 / 3), 100, accuracy: 1e-9)
    XCTAssertEqual(log.modulated(base: 10, depth: 1, cv: 5), 1000, "clamped")
  }

  func testKnobSpecDetentsAndSwitches() {
    let spec = SpectrumModel.lambdaKnob
    XCTAssertEqual(spec.detent(at: 550e-9)?.label, "Green")
    XCTAssertNil(spec.detent(at: 2e-6))
    XCTAssertFalse(spec.isSwitch)
    let generation = KnobSpec(
      id: "gen", title: "Generation", range: 1...6, defaultValue: 4, step: 1,
      detents: (1...6).map { KnobDetent(Double($0), "\($0)G") })
    XCTAssertTrue(generation.isSwitch)
    XCTAssertEqual(generation.label(for: 5), "5G")
  }

  // MARK: Time mapping and clock

  func testTimeMappingAliasAndDisplay() {
    XCTAssertEqual(TimeMapping.aliasedFrequency(60, sampleRate: 99.8), 39.8, accuracy: 1e-9)
    XCTAssertEqual(TimeMapping.aliasedFrequency(337.5, sampleRate: 120), 22.5, accuracy: 1e-9)
    XCTAssertEqual(TimeMapping.aliasedFrequency(50, sampleRate: 100), 50, accuracy: 1e-9)
    let slowed = TimeMapping.slowed(factor: 1e15)
    XCTAssertEqual(slowed.displayedFrequency(of: 5e14), 0.5, accuracy: 1e-12)
    XCTAssertFalse(slowed.isAliased(frequency: 5e14, frameRate: 60))
    XCTAssertTrue(TimeMapping.realTime.isAliased(frequency: 40, frameRate: 60))
    XCTAssertEqual(TimeMapping.heterodyned(fRef: 2128).displayedFrequency(of: 2130), 2, accuracy: 1e-9)
    XCTAssertEqual(TimeMapping.realTime.badge, "REAL TIME")
  }

  func testClockBoundsFramesNeverCatchesUpAndSteps() {
    let clock = AppClock(playing: true)
    clock.tick(at: 10)
    XCTAssertEqual(clock.time, 0, "the first tick only rebases")
    clock.tick(at: 10.5)
    XCTAssertEqual(clock.time, AppClock.maxStep, accuracy: 1e-12, "a long frame is bounded to 0.1 s")
    clock.tick(at: 10.51)
    XCTAssertEqual(clock.time, 0.11, accuracy: 1e-12)
    clock.setActive(false)
    clock.tick(at: 60)
    clock.setActive(true)
    clock.tick(at: 100)
    XCTAssertEqual(clock.time, 0.11, accuracy: 1e-12, "no wall-clock catch-up after background")
    clock.tick(at: 100.02)
    XCTAssertEqual(clock.time, 0.13, accuracy: 1e-12)
    clock.step()
    XCTAssertFalse(clock.playing, "step pauses")
    XCTAssertEqual(clock.time, 0.13 + 1.0 / 60, accuracy: 1e-12)
    clock.tick(at: 101)
    XCTAssertEqual(clock.time, 0.13 + 1.0 / 60, accuracy: 1e-12, "paused clocks hold")
    XCTAssertEqual(clock.displayTime, clock.time, accuracy: 1e-12)
  }

  // MARK: Camera and render buffers

  func testOrbitCameraLimitsAndAnchoredZoom() {
    var camera = OrbitCamera()
    camera.setAngles(yaw: 190, pitch: 120)
    XCTAssertEqual(camera.yaw, -170, accuracy: 1e-12)
    XCTAssertEqual(camera.pitch, 85)
    camera.zoom(by: 100)
    XCTAssertEqual(camera.zoom, 6)
    camera.pan(dx: 10, dy: -10)
    XCTAssertEqual(camera.panX, 1.5)
    XCTAssertEqual(camera.panY, -1.5)

    // The point under the anchor stays put while zooming.
    var c = OrbitCamera(yaw: 20, pitch: 10)
    c.pan(dx: 0.1, dy: -0.05)
    let point = SIMD3<Double>(0.4, 0.2, -0.3)
    func screen(_ cam: OrbitCamera) -> SIMD2<Double> {
      let m = cam.projectionMatrix(aspect: 1) * cam.viewMatrix
      let p = m * SIMD4(point, 1)
      return SIMD2(p.x / p.w / 2, -p.y / p.w / 2)
    }
    let anchor = screen(c)
    c.zoom(by: 1.7, anchor: anchor)
    let after = screen(c)
    XCTAssertEqual(after.x, anchor.x, accuracy: 1e-12)
    XCTAssertEqual(after.y, anchor.y, accuracy: 1e-12)
    XCTAssertTrue(c.accessibilityDescription.hasPrefix("Yaw 20 degrees, tilt 10 degrees, zoom 170 percent"))
  }

  func testSceneBufferPrimitivesAndLayout() {
    XCTAssertEqual(MemoryLayout<GlowSegment>.stride, 80, "matches GlowSegment in Shaders.metal")
    XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 128, "matches FrameUniforms in Shaders.metal")
    var buffer = SceneBuffer()
    buffer.reset(size: CGSize(width: 300, height: 200), reduceMotion: false)
    buffer.use(OrbitCamera())
    let c = GlowColor(Theme.fieldERGB)
    buffer.line(.zero, SIMD3(1, 0, 0), color: c)
    buffer.line(.zero, SIMD3(.nan, 0, 0), color: c)
    buffer.polyline([.zero, SIMD3(1, 0, 0), SIMD3(1, 1, 0)], color: c)
    buffer.trace([.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)], color: c)
    XCTAssertEqual(buffer.holo.count, 3, "non-finite lines are dropped; a 3-point polyline is 2 segments")
    XCTAssertEqual(buffer.phosphor.count, 2)
    XCTAssertEqual(buffer.phosphor[1].style.z, 10, "dash offsets accumulate along a trace")
    let centre = buffer.project(.zero)!
    XCTAssertEqual(centre.x, 150, accuracy: 1e-3)
    XCTAssertEqual(centre.y, 100, accuracy: 1e-3)
    buffer.reset(size: CGSize(width: 300, height: 200), reduceMotion: true)
    XCTAssertTrue(buffer.holo.isEmpty && buffer.phosphor.isEmpty && buffer.reduceMotion)
  }

  // MARK: Palette, formatting, launch options

  func testBandPaletteMatchesSpectraLab() {
    // spectra-lab displayColor(): 550 nm #b2ff29, 450 nm #2964ff, 650 nm #ff2929.
    func hex(_ c: RGB) -> [Int] { [c.r, c.g, c.b].map { Int(($0 * 255).rounded()) } }
    XCTAssertEqual(hex(BandPalette.rgb(forWavelength: 550e-9)), [0xB2, 0xFF, 0x29])
    XCTAssertEqual(hex(BandPalette.rgb(forWavelength: 450e-9)), [0x29, 0x64, 0xFF])
    XCTAssertEqual(hex(BandPalette.rgb(forWavelength: 650e-9)), [0xFF, 0x29, 0x29])
    XCTAssertEqual(hex(BandPalette.rgb(forWavelength: 0.1229)), [0x5F, 0xD3, 0xBC], "microwave")
    XCTAssertEqual(hex(BandPalette.rgb(forWavelength: 140.8e3)), [0x9D, 0xB0, 0xCC], "radio")
    XCTAssertEqual(BandPalette.band(forWavelength: 5e-12).key, "gamma")
  }

  func testFormattingAndCaps() {
    XCTAssertEqual(SpectraFormat.frequency(2.44e9), "2.44 GHz")
    XCTAssertEqual(SpectraFormat.wavelength(0.1229), "12.3 cm")
    XCTAssertEqual(SpectraFormat.scientific(1.8e15), "1.8 × 10¹⁵")
    XCTAssertEqual(SpectraFormat.clock(65.25), "01:05.25")
    XCTAssertEqual("λ/2 length".instrumentCaps, "λ/2 LENGTH")
    XCTAssertEqual("field in µT".instrumentCaps, "FIELD IN µT")
  }

  func testLaunchOptionsParse() {
    let o = LaunchOptions(arguments: ["Spectra", "-open", "radio/antenna", "-fakeAll", "-fakeMag=hum50", "-seed", "9"])
    XCTAssertEqual(o.openTab, .radio)
    XCTAssertEqual(o.openPath, "antenna")
    XCTAssertEqual(o.fakeMag, .hum50)
    XCTAssertEqual(o.fakeBLE, 6, "-fakeAll fills in the other fakes")
    XCTAssertEqual(o.seed, 9)
    XCTAssertTrue(o.isFaked(.microphone))
    XCTAssertTrue(LaunchOptions(arguments: ["Spectra", "-ui-testing"]).uiTesting)
    XCTAssertEqual(LaunchOptions(arguments: ["Spectra", "-open=SPIN"]).openTab, .spin)
  }

  // MARK: Simulated sensors and feedback plumbing

  func testSimulatedMagnetometerPublishesTimestampedStreamsAtItsRate() async throws {
    let registry = StreamRegistry()
    let hub = SensorHub(streams: registry, launch: LaunchOptions(arguments: ["Spectra", "-fakeMag=hum60", "-seed", "3"]))
    hub.acquire(.magnetometer, by: "test")
    try await Task.sleep(for: .milliseconds(1500))
    let x = try XCTUnwrap(registry.stream("mag.x"))
    XCTAssertEqual(x.provenance, .sim)
    XCTAssertEqual(x.unit, "µT")
    let rate = try XCTUnwrap(x.measuredRate)
    XCTAssertEqual(rate, 99.8, accuracy: 3, "99.8 Hz ± 2 % jitter")
    let snap = x.ring.snapshot()
    XCTAssertGreaterThan(snap.count, 80)
    XCTAssertEqual(snap.times, snap.times.sorted(), "timestamps never go backwards")
    XCTAssertTrue(hub.markers.contains { $0.id == "live.mains" })
    hub.release(.magnetometer, by: "test")
    XCTAssertNil(registry.stream("mag.x"), "streams leave the bus when the channel stops")
    XCTAssertEqual(hub.channel(.magnetometer).state, .idle)
  }

  func testLockedChannelsStayLockedWithoutFakes() {
    let hub = SensorHub(streams: StreamRegistry(), launch: LaunchOptions(arguments: ["Spectra"]))
    if case .locked = hub.channel(.nfc).state {} else { XCTFail("NFC is locked on a free team") }
    XCTAssertEqual(hub.channel(.nfc).provenance, .locked)
    XCTAssertEqual(hub.channel(.uwb).provenance, .needsPeer)
  }

  func testPCMRingAndResampler() {
    let ring = PCMRing(capacity: 8)
    ring.write((0..<10).map(Float.init))
    XCTAssertEqual(ring.available, 8, "overflow drops the oldest")
    var out = [Float](repeating: -1, count: 4)
    let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
    XCTAssertEqual(n, 4)
    XCTAssertEqual(out, [2, 3, 4, 5])
    XCTAssertEqual(ring.available, 4)
    let up = HumSynth.resample([0, 1, 2, 3], from: 24_000, to: 48_000)
    XCTAssertEqual(up.count, 8)
    XCTAssertEqual(up[1], 0.5, accuracy: 1e-6)
    XCTAssertEqual(HumSynth.resample([1, 2, 3], from: 48_000, to: 48_000), [1, 2, 3])
  }

  // MARK: Stub physics oracles

  func testHalfWaveDipolePattern() {
    // gyre-integration.md §10: λ/2 dipole F² at θ = 30° is −7.5808 dB.
    XCTAssertEqual(RadioModel.halfWaveDipoleGainDB(theta: .pi / 6), -7.5808, accuracy: 1e-4)
    XCTAssertEqual(RadioModel.halfWaveDipoleGainDB(theta: .pi / 2), 0, accuracy: 1e-12)
    XCTAssertEqual(RadioModel.halfWaveDipoleGainDB(theta: 0), -60)
  }

  func testEarthFieldProtonPrecession() {
    // gyre-integration.md §10 (review-corrected): 50 µT → 2128.8192715 Hz.
    let spin = SpinModel()
    spin.fieldTesla = 50e-6
    XCTAssertEqual(spin.larmorFrequency / 2128.8192715, 1, accuracy: 1e-9)
  }
}
