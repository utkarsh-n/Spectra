import XCTest
import simd

@testable import Spectra

/// Live tests (SPEC-build §5): the fakes write timestamped rings at their declared rates, the
/// hum60 magnetometer fake shows its 60 Hz line folded to 39.8 Hz in an FFT, the stream ids
/// other slices hard-code stay put, the hub keeps the foundation's API, and the pure Live
/// analysis (aliasing, resampling, light meter, air, Bluetooth distance, turntable) gives the
/// worked values.
@MainActor
final class LiveTests: XCTestCase {
  private func hub(_ args: [String]) -> SensorHub {
    SensorHub(streams: StreamRegistry(), launch: LaunchOptions(arguments: ["Spectra", "-ui-testing"] + args))
  }

  // MARK: Fakes: timestamped rings at the declared rates

  func testEveryFakePublishesTimestampedStreamsAtItsDeclaredRate() async throws {
    let hub = hub(["-fakeAll", "-seed", "3"])
    for id in SensorID.allCases { await hub.source(id).start() }
    try await Task.sleep(for: .milliseconds(2600))
    hub.refreshAll()
    for id in SensorID.allCases {
      let source = hub.source(id)
      XCTAssertEqual(source.state, .running, "\(id) runs simulated with -fakeAll")
      XCTAssertFalse(source.streams.isEmpty, "\(id) publishes streams")
      for stream in source.streams {
        XCTAssertNotNil(hub.streams.stream(stream.id), "\(stream.id) is on the bus")
        XCTAssertEqual(stream.group, id.streamGroup, "\(stream.id) sits in its sensor's group")
        XCTAssertEqual(stream.provenance, .sim, "\(stream.id) is badged SIM")
        let snap = stream.ring.snapshot()
        XCTAssertEqual(snap.times, snap.times.sorted(), "\(stream.id): timestamps never go backwards")
        if let last = snap.times.last {
          XCTAssertLessThanOrEqual(last, SignalClock.now() + 0.05, "\(stream.id): no samples from the future")
        }
        // Regular streams at ≥ 1 Hz: the measured rate matches the declared one.
        if !stream.isIrregular, stream.nominalRate >= 1, stream.id != LiveStreams.nfcTap.id {
          let rate = try XCTUnwrap(stream.measuredRate, "\(stream.id) has a measured rate")
          XCTAssertEqual(rate, stream.nominalRate, accuracy: max(0.05 * stream.nominalRate, 0.15), "\(stream.id) rate")
        } else if stream.id == LiveStreams.proximity.id || stream.id == LiveStreams.nfcTap.id {
          continue
        } else {
          XCTAssertGreaterThan(snap.count, 0, "\(stream.id) has samples")
        }
      }
    }
    // Bluetooth: one irregular stream per simulated radio (-fakeAll → 6), whole-dB RSSI.
    let ble = hub.streams.streams(in: StreamGroup.bluetooth)
    XCTAssertEqual(ble.count, 6)
    for s in ble {
      XCTAssertTrue(s.isIrregular)
      XCTAssertTrue(s.isEM)
      XCTAssertEqual(try XCTUnwrap(s.lambda), SpectrumMarker.lambda(forFrequency: 2.44e9), accuracy: 1e-12)
      for v in s.ring.snapshot().values { XCTAssertEqual(v, v.rounded(), "RSSI is quantized to 1 dB") }
    }
    // A simulated battery charging: the Qi marker is SIM, not INFERRED from a real battery.
    XCTAssertEqual(hub.charging.batteryState, 2)
    XCTAssertEqual(hub.markers.first { $0.id == "live.qi" }?.provenance, .sim)
    // Proximity monitoring is off (and impossible on the simulated phone): no empty stream.
    XCTAssertNil(hub.streams.stream(LiveStreams.proximity.id), "device.proximity is on the bus only while monitoring is on")
    // The NFC fake counts every tap, and the rate words say what is measured.
    XCTAssertEqual(hub.nfc.taps, Int(try XCTUnwrap(hub.streams.stream(LiveStreams.nfcTap.id)).ring.totalAppended))
    XCTAssertEqual(hub.bluetooth.rateText, "event-driven")
    XCTAssertEqual(hub.barometer.rateText, SpectraFormat.rate(try XCTUnwrap(hub.barometer.measuredRate)))
    for id in SensorID.allCases { hub.source(id).stop() }
    XCTAssertTrue(hub.streams.streams.isEmpty, "every stream leaves the bus when its source stops")
  }

  func testMicrophoneFakeRunsAtAudioRateWithLevelBlocks() async throws {
    let hub = hub(["-fakeMic=tone:1000"])
    await hub.microphone.start()
    try await Task.sleep(for: .milliseconds(1200))
    hub.refreshAll()
    let left = try XCTUnwrap(hub.streams.stream("mic.left"))
    XCTAssertEqual(try XCTUnwrap(left.measuredRate), 48_000, accuracy: 100)
    let level = try XCTUnwrap(hub.streams.stream("mic.level"))
    XCTAssertEqual(try XCTUnwrap(level.ring.latest?.value), -9.03, accuracy: 0.2, "0.5 FS sine: RMS −9.03 dBFS")
    XCTAssertEqual(try XCTUnwrap(hub.microphone.loudestHz), 1000, accuracy: 6, "4096-point FFT finds the tone")
    XCTAssertTrue(hub.markers.contains { $0.id == "live.sound" && !$0.isEM })
    // The card's spectrum (analyzer mutated in place) finds the same tone, run after run.
    let audio = AudioSpectrumModel()
    audio.update(left)
    XCTAssertEqual(audio.bins.count, AudioSpectrumModel.count / 2 + 1)
    let binWidth = audio.sampleRate / Double(AudioSpectrumModel.count)
    let loudest = try XCTUnwrap(audio.bins.indices.max { audio.bins[$0] < audio.bins[$1] })
    XCTAssertEqual(Double(loudest) * binWidth, 1000, accuracy: 2 * binWidth)
    hub.microphone.stop()
  }

  // MARK: Magnetometer hum60: the 39.8 Hz alias

  func testHum60FakeShowsThe39Point8HzAliasInAnFFT() throws {
    // Drive the generator offline on its own clock: 12 s of samples at 99.8 Hz ± 2 %.
    let raw = (LiveStreams.magRaw + [LiveStreams.magRawNorm]).map {
      $0.make(provenance: .sim, group: StreamGroup.magnetometer, rate: 99.8)
    }
    let calibrated = (LiveStreams.mag + [LiveStreams.magNorm]).map {
      $0.make(provenance: .sim, group: StreamGroup.magnetometer, rate: 99.8)
    }
    var generator = MagnetometerGenerator(
      calibrated: calibrated, raw: raw, mode: .hum60, pose: SimPose(), t0: 0,
      grid: SampleGrid(rate: 99.8, jitter: 0.02, start: 0, seed: 11), rng: SimRandom(seed: 11))
    generator.produce(until: 12)
    let x = raw[0].ring.snapshot()
    let fs = try XCTUnwrap(x.measuredRate)
    XCTAssertEqual(fs, 99.8, accuracy: 0.5, "99.8 Hz ± 2 % jitter")
    let spectrum = try XCTUnwrap(
      LiveAnalysis.spectrum(axes: (0..<3).map { raw[$0].ring.snapshot() }, rate: fs, count: 1024, peakAbove: 2))
    let peak = try XCTUnwrap(spectrum.peak)
    XCTAssertEqual(peak.frequency, RF.DSP.aliasFrequency(60, sampleRate: fs), accuracy: 0.1, "60 Hz folds to fs − 60")
    XCTAssertEqual(peak.frequency, 39.8, accuracy: 0.6)
    XCTAssertGreaterThan(peak.levelDB - spectrum.floorDB, 15, "the 1.6 µT line stands well above the noise")
    XCTAssertGreaterThan(LiveAnalysis.intervalJitter(x.times), 0.01, "the hum fake's clock jitters, so it is resampled")
    // The 120 Hz harmonic (0.4 µT) folds to 20.2 Hz, well above the floor.
    let harmonic = try XCTUnwrap(spectrum.level(near: RF.DSP.aliasFrequency(120, sampleRate: fs), tolerance: 0.3))
    XCTAssertGreaterThan(harmonic - spectrum.floorDB, 10)
    XCTAssertEqual(LiveAnalysis.detectMains(in: spectrum), 60)
    // A clean Earth field shows no mains line.
    let quiet = (LiveStreams.magRaw + [LiveStreams.magRawNorm]).map { $0.make(provenance: .sim, group: StreamGroup.magnetometer) }
    var earth = MagnetometerGenerator(
      calibrated: calibrated, raw: quiet, mode: .earth, pose: SimPose(), t0: 0,
      grid: SampleGrid(rate: 100, jitter: 0.01, start: 0, seed: 12), rng: SimRandom(seed: 12))
    earth.produce(until: 12)
    let quietSpectrum = try XCTUnwrap(
      LiveAnalysis.spectrum(axes: (0..<3).map { quiet[$0].ring.snapshot() }, rate: 100, count: 1024, peakAbove: 2))
    XCTAssertNil(LiveAnalysis.detectMains(in: quietSpectrum))
  }

  func testHubMagnetometerFindsTheAliasLive() async throws {
    let hub = hub(["-fakeMag=hum60", "-seed", "4"])
    hub.magnetometer.fftCount = 256
    hub.acquire(.magnetometer, by: "test")
    try await Task.sleep(for: .milliseconds(3200))
    hub.refreshAll()
    let spectrum = try XCTUnwrap(hub.magnetometer.spectrum)
    XCTAssertEqual(try XCTUnwrap(spectrum.peak?.frequency), 39.8, accuracy: 0.8)
    XCTAssertEqual(hub.magnetometer.detectedMains, 60)
    let mains = try XCTUnwrap(hub.markers.first { $0.id == "live.mains" })
    XCTAssertEqual(mains.frequency, 60, accuracy: 1e-9)
    XCTAssertEqual(mains.provenance, .sim)
    let earth = try XCTUnwrap(hub.magnetometer.earthField)
    XCTAssertEqual(earth.magnitude * 1e6, (22.0 * 22 + 40 * 40).squareRoot(), accuracy: 2.5, "|B| of the (0, 22, −40) µT fake")
    hub.release(.magnetometer, by: "test")
    XCTAssertNil(hub.streams.stream("mag.raw.x"))
  }

  // MARK: Stream ids (other slices hard-code these)

  func testRegistryIdsAreStable() {
    let ids = SensorID.allCases.flatMap { LiveStreams.catalog($0).map(\.id.rawValue) }
    XCTAssertEqual(
      ids,
      [
        "accel.x", "accel.y", "accel.z", "accel.user.x", "accel.user.y", "accel.user.z", "gravity.x", "gravity.y", "gravity.z",
        "gyro.x", "gyro.y", "gyro.z", "attitude.pitch", "attitude.yaw", "attitude.roll",
        "mag.x", "mag.y", "mag.z", "mag.norm", "mag.raw.x", "mag.raw.y", "mag.raw.z", "mag.raw.norm",
        "baro.pressure", "baro.altitude",
        "mic.left", "mic.level",
        "net.rtt", "net.quality",
        "gnss.hacc", "gnss.vacc", "gnss.speed", "gnss.altitude", "gnss.heading.true", "gnss.heading.magnetic",
        "light.lux", "light.cct", "light.ev", "light.flicker",
        "battery.level", "battery.state", "device.thermal", "device.proximity",
        "uwb.distance", "uwb.azimuth",
        "nfc.tap",
      ])
    XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
    let uuid = UUID(uuidString: "0000ABCD-0000-4000-8000-000000000001")!
    XCTAssertEqual(LiveStreams.bleRSSI(uuid).rawValue, "ble.0000ABCD-0000-4000-8000-000000000001.rssi")
    XCTAssertEqual(LiveStreams.sensor(for: LiveStreams.bleRSSI(uuid)), .bluetooth)
    for id in SensorID.allCases {
      for spec in LiveStreams.catalog(id) { XCTAssertEqual(LiveStreams.sensor(for: spec.id), id, spec.id.rawValue) }
    }
    XCTAssertNil(LiveStreams.sensor(for: "spin.fid"))
  }

  func testRunningSourcesPublishOnlyCatalogIds() async throws {
    let hub = hub(["-fakeAll", "-seed", "9"])
    for id in SensorID.allCases { await hub.source(id).start() }
    try await Task.sleep(for: .milliseconds(400))
    hub.refreshAll()
    for id in SensorID.allCases where id != .bluetooth {
      let published = Set(hub.source(id).streams.map(\.id))
      XCTAssertTrue(published.isSubset(of: Set(LiveStreams.catalog(id).map(\.id))), "\(id): \(published)")
    }
    for s in hub.bluetooth.streams {
      XCTAssertTrue(s.id.rawValue.hasPrefix("ble.") && s.id.rawValue.hasSuffix(".rssi"))
    }
    for id in SensorID.allCases { hub.source(id).stop() }
  }

  // MARK: Hub API (unchanged from the foundation)

  func testAcquireAndReleaseAreReferenceCounted() async throws {
    let hub = hub(["-fakeBaro=stairs"])
    hub.acquire(.barometer, by: "a")
    hub.acquire(.barometer, by: "b")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(hub.channel(.barometer).state, .running)
    XCTAssertEqual(hub.holders(of: .barometer), ["a", "b"])
    hub.release(.barometer, by: "a")
    XCTAssertEqual(hub.channel(.barometer).state, .running, "still held by b")
    hub.releaseAll(by: "b")
    XCTAssertEqual(hub.channel(.barometer).state, .idle)
    XCTAssertNil(hub.streams.stream("baro.pressure"))
    var settings = AppSettings()
    settings.disabledSensors = [.barometer]
    hub.apply(settings)
    hub.acquire(.barometer, by: "a")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(hub.channel(.barometer).state, .idle, "a sensor switched off in Settings never starts")
    XCTAssertFalse(hub.isEnabled(.barometer))
    // So its card, Dials switch and census switch say where it was switched off (no Start
    // control that would do nothing); the others are not affected.
    XCTAssertTrue(hub.isSwitchedOff(hub.barometer))
    XCTAssertFalse(hub.isSwitchedOff(hub.magnetometer))
  }

  func testLockedAndPeerSourcesWithoutFakes() async {
    let hub = hub([])
    await hub.nfc.start()
    await hub.uwb.start()
    if case .locked = hub.nfc.state {} else { XCTFail("NFC stays locked") }
    if case .locked = hub.uwb.state {} else { XCTFail("UWB needs a peer") }
    XCTAssertEqual(hub.nfc.provenance, .locked)
    XCTAssertEqual(hub.uwb.provenance, .needsPeer)
    // The cards word them differently: UWB waits for a second device, NFC is locked.
    XCTAssertTrue(hub.uwb.waitsForPeer)
    XCTAssertEqual(hub.uwb.stateLabel, "Needs peer")
    XCTAssertFalse(hub.nfc.waitsForPeer)
    XCTAssertEqual(hub.nfc.stateLabel, "Locked")
    XCTAssertFalse(hub.uwb.capabilities.isEmpty, "the census still reports UWB capability flags")
  }

  /// A regular source whose timestamps do not span a measurement yet is "measuring rate", not
  /// "event-driven" (the census said so of a GNSS fix on its way); Bluetooth is event-driven.
  func testRateWordsSayWhatIsMeasured() async {
    let hub = hub(["-fakeGNSS", "-fakeBLE=2"])
    await hub.location.start()
    XCTAssertNil(hub.location.measuredRate)
    XCTAssertEqual(hub.location.rateText, "measuring rate")
    await hub.bluetooth.start()
    XCTAssertEqual(hub.bluetooth.rateText, "event-driven")
    hub.location.stop()
    hub.bluetooth.stop()
  }

  // MARK: Pure analysis oracles

  func testAliasArithmetic() {
    let lines = LiveAnalysis.mainsLines(mains: 60, sampleRate: 99.8)
    XCTAssertEqual(lines[0].alias, 39.8, accuracy: 1e-9)
    XCTAssertEqual(lines[1].alias, 20.2, accuracy: 1e-9)
    XCTAssertEqual(LiveAnalysis.mainsLines(mains: 60, sampleRate: 100)[0].alias, 40, accuracy: 1e-12)
    XCTAssertEqual(LiveAnalysis.mainsLines(mains: 50, sampleRate: 99.8)[0].alias, 49.8, accuracy: 1e-9)
    XCTAssertTrue(lines[0].isFolded)
  }

  func testUniformResamplerInterpolatesJitteredTimes() {
    let times = [0.0, 0.011, 0.019, 0.031, 0.04, 0.052]
    let values = times.map { Float(2 * $0 + 1) }  // a straight line survives linear interpolation
    let out = LiveAnalysis.resample(times: times, values: values, rate: 100, count: 5)
    XCTAssertEqual(out.count, 5)
    for (k, v) in out.enumerated() {
      let t = 0.052 - Double(4 - k) / 100
      XCTAssertEqual(Double(v), 2 * t + 1, accuracy: 1e-5)
    }
    XCTAssertTrue(LiveAnalysis.resample(times: [1], values: [1], rate: 100, count: 8).isEmpty)
    XCTAssertEqual(LiveAnalysis.intervalJitter([0, 0.01, 0.02, 0.03]), 0, accuracy: 1e-9)
    // On a steady clock the spectrum uses the samples as they are: a bin-centred tone reads 20·log10 A.
    let steady = TimedSamples(values: (0..<256).map { Float(2 * sin(2 * Double.pi * 25 * Double($0) / 100)) }, times: (0..<256).map { Double($0) / 100 })
    let s = LiveAnalysis.spectrum(axes: [steady], rate: 100, count: 256)
    XCTAssertEqual(Double(s?.peak?.frequency ?? 0), 25, accuracy: 0.05)
    XCTAssertEqual(Double(s?.peak?.levelDB ?? 0), 20 * log10(2), accuracy: 0.1)
    var ramp: [Float] = (0..<64).map { 3 + 0.5 * Float($0) }
    LiveAnalysis.removeTrend(&ramp, linear: true)
    XCTAssertLessThan(ramp.map(abs).max() ?? 1, 1e-4, "a straight line detrends to zero")
  }

  func testLightMeterFormulas() throws {
    // f/1.78, 1/60 s, ISO 100: EV100 = log2(1.78² × 60) = 7.5707.
    let ev = try XCTUnwrap(LightMeter.ev100(aperture: 1.78, exposure: 1.0 / 60, iso: 100))
    XCTAssertEqual(ev, log2(1.78 * 1.78 * 60), accuracy: 1e-12)
    XCTAssertEqual(ev, 7.5707, accuracy: 1e-4)
    XCTAssertEqual(try XCTUnwrap(LightMeter.ev100(aperture: 1.78, exposure: 1.0 / 60, iso: 400)), ev - 2, accuracy: 1e-12)
    XCTAssertEqual(LightMeter.lux(ev100: 0), 2.5, accuracy: 1e-12, "E = 2.5 × 2^EV with C = 250")
    XCTAssertEqual(LightMeter.ev100(lux: 2560), 10, accuracy: 1e-12)
    XCTAssertNil(LightMeter.ev100(aperture: 0, exposure: 1, iso: 100))
    XCTAssertEqual(LightMeter.wienPeak(kelvin: 3100), 2.897_771_955e-3 / 3100, accuracy: 1e-15)
    XCTAssertEqual(LightMeter.rowRate(rows: 120, frameRate: 30), 3600)
  }

  func testAirAnalysisMatchesTheVerifiedReference() {
    // ρ ↔ e round trip against the RF engine's AirState.
    let state = AirAnalysis.airState(pressureHPa: 1013.25, tempC: 15, humidity: 50)
    XCTAssertEqual(state.vapourPressure, AirHere.vaporPressure(tempC: 15, humidity: 50, pressureHPa: 1013.25), accuracy: 1e-9)
    let air = AirAnalysis.evaluate(
      pressureHPa: 1013.25, tempC: 15, humidity: 50, gradient: -40, height: 1.5, latitudeDegrees: 45, ellipsoidalHeight: 0)
    XCTAssertEqual(air.refractivity, 311.37, accuracy: 0.01, "P.453 eq. 2, 15 °C, 50 % RH")
    XCTAssertEqual(air.kFactor, 1.34199, accuracy: 1e-5)
    XCTAssertEqual(air.zenithDelay, 2.30697, accuracy: 1e-5, "Saastamoinen ZHD at 45°, sea level")
    XCTAssertEqual(air.geometricHorizon, 4372, accuracy: 1)
    XCTAssertEqual(AirHere.radioHorizon(height: 1.5, k: 4.0 / 3), 5048, accuracy: 1)
    XCTAssertEqual(air.radioHorizon, AirHere.radioHorizon(height: 1.5, k: air.kFactor), accuracy: 1e-9)
    XCTAssertEqual(air.oxygen60GHz, 14.5, accuracy: 0.2, "P.676 γ_o at 60 GHz near the standard atmosphere")
    let ducting = AirAnalysis.evaluate(
      pressureHPa: 1013.25, tempC: 15, humidity: 50, gradient: -200, height: 1.5, latitudeDegrees: 45, ellipsoidalHeight: 0)
    XCTAssertEqual(ducting.radioHorizon, .infinity, "past −157 N/km rays follow the Earth")
    XCTAssertEqual(AirAnalysis.lightPath(roundTrip: 1e-3), RF.Const.c / 2000, accuracy: 1e-9)
  }

  func testBluetoothDistanceModel() {
    XCTAssertEqual(RadioMaps.bleLossAt1m, 40.2, accuracy: 0.05, "FSPL at 1 m, 2.44 GHz")
    let oneMetre = RadioMaps.bleDistance(rssi: -RadioMaps.bleLossAt1m, txPower: 0, exponent: 2)
    XCTAssertEqual(oneMetre, 1, accuracy: 1e-9)
    XCTAssertEqual(RadioMaps.bleDistance(rssi: -RadioMaps.bleLossAt1m - 20, txPower: 0, exponent: 2), 10, accuracy: 1e-9)
    XCTAssertEqual(RadioMaps.bleDistance(rssi: -RadioMaps.bleLossAt1m - 30, txPower: nil, exponent: 3), 10, accuracy: 1e-9)
    XCTAssertEqual(RadioMaps.advertisingChannelsMHz, [2402, 2426, 2480])
  }

  func testRadioMaps() {
    XCTAssertEqual(RadioMaps.cellular("CTRadioAccessTechnologyNRNSA"), RadioMaps.Cellular(label: "5G NR NSA", generation: "5G", systemID: "nr-fr1"))
    XCTAssertEqual(RadioMaps.cellular("CTRadioAccessTechnologyLTE").systemID, "lte")
    XCTAssertEqual(RadioMaps.cellular("CTRadioAccessTechnologyHSDPA").generation, "3G")
    XCTAssertEqual(RadioMaps.dataPath("cell.nsa.mmwave")?.systemID, "nr-fr2")
    XCTAssertEqual(RadioMaps.dataPath("wifi.ax")?.label, "Wi-Fi 6 (802.11ax)")
    for code in ["wifi.ac", "cell.lte", "cell.sa.sub6"] { XCTAssertNotNil(RadioMaps.dataPath(code)) }
    for radio in RadioMaps.phoneRadios {
      if let id = radio.systemID { XCTAssertNotNil(RF.SystemsCatalog.system(id: id), "\(id) is a catalog system") }
      XCTAssertGreaterThan(radio.frequency, 0)
    }
    let fake = NetworkFake(technologies: ["lte", "nsa"], wifi: false)
    XCTAssertEqual(fake.technology(at: 3), "CTRadioAccessTechnologyLTE")
    XCTAssertEqual(fake.technology(at: 16), "CTRadioAccessTechnologyNRNSA")
    XCTAssertEqual(fake.dataPath(at: 16), "cell.nsa.sub6")
    XCTAssertEqual(fake.quality(at: 31), 2)
  }

  func testTurntableBinnerAndStatistics() throws {
    var b = YawBinner()
    // Three and a half turns, 10 adverts per bin per turn, a clean dipole-like pattern.
    var yaw = -180.0
    for _ in 0..<(36 * 10 * 7 / 2) {
      let theta = (yaw + 90) * .pi / 180
      b.add(yaw: yaw, rssi: -60 + max(TurntableModel.halfWaveDipolePatternDB(theta: theta), -15))
      yaw += 1
      if yaw >= 180 { yaw -= 360 }
    }
    XCTAssertEqual(b.turns, 3.5, accuracy: 0.01, "unwrapping across ±180°")
    XCTAssertEqual(b.filledBins, 36)
    XCTAssertEqual(b.sampleCount, 36 * 10 * 7 / 2, "every advert is binned (35 per bin, under the 120 cap)")
    XCTAssertTrue(b.isComplete)
    XCTAssertFalse(b.isFadingDominated, "a clean pattern is not buried in fading")
    let ftb = try XCTUnwrap(b.frontToBack)
    XCTAssertEqual(ftb.decibels, 0, accuracy: 0.5, "a dipole is front-back symmetric")
    XCTAssertEqual(YawBinner.bin(forYaw: -5), 35)
    XCTAssertEqual(YawBinner.bin(forYaw: 365), 0)
    let model = YawBinner.modelPattern(peakYaw: 45)
    XCTAssertEqual(model[YawBinner.bin(forYaw: 45)], 0, accuracy: 0.05, "model broadside sits on the peak")
    XCTAssertEqual(model.min() ?? 0, -15, accuracy: 1e-9)
    // Pure Rayleigh fading per bin reads ≈ 5.57 dB: the experiment says so.
    var faded = YawBinner()
    var rng = SimRandom(seed: 2)
    for i in 0..<(36 * 40) {
      let power = -log(max(rng.uniform(), 1e-12))
      faded.add(yaw: Double(i % 36) * 10 + 5, rssi: -60 + 10 * log10(power))
    }
    XCTAssertEqual(try XCTUnwrap(faded.meanDeviation), TurntableStatistics.rayleighDecibelSpread, accuracy: 0.8)
    XCTAssertTrue(faded.isFadingDominated)
  }

  func testCrowdedBluetoothKeepsTheBusInStepWithTheTable() async throws {
    // More radios than the table keeps (40): evicted radios must leave the bus as well.
    let hub = hub(["-fakeBLE=48", "-seed", "5"])
    hub.acquire(.bluetooth, by: "test")
    try await Task.sleep(for: .milliseconds(4000))
    hub.refreshAll()
    let onBus = Set(hub.streams.streams(in: StreamGroup.bluetooth).map(\.id))
    let inTable = Set(hub.bluetooth.devices.map { LiveStreams.bleRSSI($0.id) })
    XCTAssertLessThanOrEqual(hub.bluetooth.devices.count, BLEDeviceTable.capacity)
    XCTAssertEqual(onBus, inTable, "every BLE stream on the bus belongs to a radio in the table")
    XCTAssertEqual(Set(hub.bluetooth.streams.map(\.id)), inTable)
    hub.release(.bluetooth, by: "test")
    XCTAssertTrue(hub.streams.streams(in: StreamGroup.bluetooth).isEmpty)
  }

  func testSimulatedCameraReadoutsAgree() throws {
    for locked in [false, true] {
      let r = LightChannel.simulatedReading(lux: 300, flickerLocked: locked)
      let ev = try XCTUnwrap(
        LightMeter.ev100(
          aperture: try XCTUnwrap(r.aperture), exposure: try XCTUnwrap(r.exposure), iso: try XCTUnwrap(r.iso),
          targetOffset: try XCTUnwrap(r.targetOffset)))
      XCTAssertEqual(ev, LightMeter.ev100(lux: 300), accuracy: 1e-9, "ISO, shutter, aperture and offset give the shown EV")
      XCTAssertLessThanOrEqual(try XCTUnwrap(r.iso), 3200)
      XCTAssertEqual(try XCTUnwrap(r.exposure), locked ? 1.0 / 4000 : 1.0 / 60, accuracy: 1e-12)
    }
  }

  func testFlickerFakeShowsTheLineOnlyWithTheShortExposure() throws {
    func spectrum(probe: Bool, seed: UInt64) throws -> LiveAnalysis.Spectrum {
      let stream = LiveStreams.flicker.make(provenance: .sim, group: StreamGroup.light, rate: 2400)
      var gen = FlickerGenerator(
        stream: stream, flickerHz: 120, probe: Latest(probe), grid: SampleGrid(rate: 2400, start: 0, seed: seed),
        rng: SimRandom(seed: seed))
      gen.produce(until: 1.5)
      return try XCTUnwrap(LiveAnalysis.spectrum(axes: [stream.ring.snapshot(last: 2048)], rate: 2400, count: 2048))
    }
    let locked = try spectrum(probe: true, seed: 3)
    XCTAssertGreaterThan(try XCTUnwrap(locked.level(near: 120, tolerance: 2)) - locked.floorDB, 20, "1/4000 s: the 120 Hz ripple stands out")
    XCTAssertEqual(try XCTUnwrap(LightMeter.flickerLine(in: locked)), 120, accuracy: 2 * locked.binWidth, "the card names it")
    let auto = try spectrum(probe: false, seed: 3)
    XCTAssertLessThan(try XCTUnwrap(auto.level(near: 120, tolerance: 2)) - auto.floorDB, 10, "1/60 s spans two flicker periods: the line averages away")
    // A steady light's noise must never be named a flicker line (a 10 dB test called a noise
    // spike "a flicker line near 109 Hz").
    for seed: UInt64 in 1...16 {
      XCTAssertNil(LightMeter.flickerLine(in: try spectrum(probe: false, seed: seed)), "seed \(seed): noise is not flicker")
    }
  }

  func testWholeNumberReadoutsUseTheTypographicMinus() async throws {
    XCTAssertEqual(liveWhole(-42.4), "−42")
    XCTAssertEqual(liveWhole(-0.4), "0")
    XCTAssertEqual(liveWhole(3.6), "4")
    XCTAssertEqual(liveWhole(.nan), "—")
    let hub = hub(["-fakeBLE=3", "-seed", "6"])
    hub.acquire(.bluetooth, by: "test")
    try await Task.sleep(for: .milliseconds(1500))
    hub.refreshAll()
    let readout = try XCTUnwrap(hub.bluetooth.primaryReadout)
    XCTAssertTrue(readout.contains("−") && !readout.contains("-"), "RSSI reads like every other readout: \(readout)")
    hub.release(.bluetooth, by: "test")
  }

  func testLevelAccumulatorWritesOneLevelPer1024Samples() {
    let level = LiveStreams.micLevel.make(provenance: .sim, group: StreamGroup.audio)
    let acc = LevelAccumulator()
    let sine = (0..<1500).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
    acc.feed(sine, start: 10, interval: 1.0 / 48_000, into: level)
    acc.feed(sine, start: 10 + 1500.0 / 48_000, interval: 1.0 / 48_000, into: level)
    let snap = level.ring.snapshot()
    XCTAssertEqual(snap.count, 2, "3000 samples → two full 1024-sample blocks")
    XCTAssertEqual(Double(snap.values[0]), 20 * log10(0.5 / 2.0.squareRoot()), accuracy: 0.05)
    XCTAssertEqual(snap.times[0], 10 + 1023.0 / 48_000, accuracy: 1e-9, "stamped at the block's last sample")
  }

  func testBluetoothFakeFillsTheDeviceTable() {
    let table = BLEDeviceTable(provenance: .sim)
    var gen = BluetoothGenerator(
      table: table, beacons: BluetoothGenerator.room(count: 8, start: 0, seed: 1), pose: SimPose(), rng: SimRandom(seed: 1))
    gen.produce(until: 4)
    let devices = table.snapshot()
    XCTAssertEqual(devices.count, 8)
    XCTAssertEqual(devices.map(\.averageRSSI), devices.map(\.averageRSSI).sorted(by: >), "strongest (averaged) first")
    for d in devices {
      let snap = d.stream.ring.snapshot()
      XCTAssertGreaterThan(snap.count, 2)
      XCTAssertEqual(snap.times, snap.times.sorted())
      XCTAssertTrue(d.stream.isIrregular)
      // The average follows the adverts: inside their range, and the newest advert is the last value.
      let values = snap.values.map(Double.init)
      XCTAssertGreaterThanOrEqual(d.averageRSSI, values.min() ?? 0)
      XCTAssertLessThanOrEqual(d.averageRSSI, values.max() ?? 0)
      XCTAssertEqual(d.lastRSSI, values.last ?? 0)
    }
    XCTAssertEqual(table.prune(quiet: 1, now: 100).count, 8, "quiet radios are forgotten")
    XCTAssertTrue(table.snapshot().isEmpty)
  }
}
