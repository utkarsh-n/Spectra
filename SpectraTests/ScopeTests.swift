import XCTest

@testable import Spectra

/// Scope oracles (SPEC-build §5): trigger edges, level, slope, hysteresis and holdoff;
/// frequency by zero crossing and FFT within 0.5 %; Pk-Pk / RMS of known waveforms; min/max
/// decimation keeps peaks; roll ordering; XY pairing by timestamp; math; coupling filters;
/// scales and timebase limits; aliasing; stream resolution by meaning; CSV; settings and
/// presets; the probe streams; the time–frequency plumbing; and the model end to end.
@MainActor
final class ScopeTests: XCTestCase {
  private func makeApp() -> AppModel {
    let name = "Spectra.scopetests.\(UUID().uuidString)"
    // Each test's defaults suite is removed when the test ends (a Sendable teardown block, so
    // no main-actor state is touched from XCTest's nonisolated tearDown).
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return AppModel(launch: LaunchOptions(arguments: ["Spectra", "-ui-testing"]), defaults: UserDefaults(suiteName: name)!)
  }

  /// A uniformly sampled signal.
  private func sampled(rate: Double, duration: Double, start: Double = 0, _ f: (Double) -> Double) -> (values: [Float], times: [Double]) {
    let n = Int((duration * rate).rounded())
    let times = (0..<n).map { start + Double($0) / rate }
    return (times.map { Float(f($0)) }, times)
  }

  // MARK: - Trigger

  func testTriggerFindsRisingAndFallingEdgesAtTheLevel() {
    let s = sampled(rate: 1000, duration: 2) { sin(2 * .pi * 5 * $0) }
    let rising = ScopeEngine.triggerTimes(values: s.values, times: s.times, level: 0.5, slope: .rising)
    XCTAssertEqual(rising.count, 10)
    for (k, t) in rising.enumerated() {
      XCTAssertEqual(t, (1.0 / 12 + Double(k)) / 5, accuracy: 2e-4, "sin = 0.5 rising at (1/12 + k)/5")
    }
    let falling = ScopeEngine.triggerTimes(values: s.values, times: s.times, level: 0.5, slope: .falling)
    XCTAssertEqual(falling.count, 10)
    for (k, t) in falling.enumerated() {
      XCTAssertEqual(t, (5.0 / 12 + Double(k)) / 5, accuracy: 2e-4)
    }
    // Level above the signal: nothing.
    XCTAssertTrue(ScopeEngine.triggerTimes(values: s.values, times: s.times, level: 1.2, slope: .rising).isEmpty)
  }

  func testTriggerHoldoffAndNotBefore() {
    let s = sampled(rate: 1000, duration: 2) { sin(2 * .pi * 5 * $0) }
    let held = ScopeEngine.triggerTimes(values: s.values, times: s.times, level: 0, slope: .rising, holdoff: 0.3)
    // Rising zeros every 0.2 s; a 0.3 s holdoff accepts every other one.
    XCTAssertEqual(held.count, 5)
    for k in 1..<held.count { XCTAssertEqual(held[k] - held[k - 1], 0.4, accuracy: 2e-4) }
    let late = ScopeEngine.triggerTimes(values: s.values, times: s.times, level: 0, slope: .rising, notBefore: 1.05)
    XCTAssertEqual(late.first ?? 0, 1.2, accuracy: 2e-4)
    XCTAssertTrue(late.allSatisfy { $0 >= 1.05 })
  }

  func testTriggerHysteresisIgnoresChatterOnAnEdge() {
    let values: [Float] = [0, 0.6, 0.45, 0.6, 0.45, 0.6, 0, 0.6]
    let times = values.indices.map(Double.init)
    let plain = ScopeEngine.triggerTimes(values: values, times: times, level: 0.5, slope: .rising)
    XCTAssertEqual(plain.count, 4, "without hysteresis every chatter re-triggers")
    let hyst = ScopeEngine.triggerTimes(values: values, times: times, level: 0.5, slope: .rising, hysteresis: 0.2)
    XCTAssertEqual(hyst.count, 2, "with hysteresis only real edges count")
    XCTAssertEqual(hyst[0], 0 + (0.5 - 0) / 0.6, accuracy: 1e-6, "interpolated between samples (Float values)")
    XCTAssertEqual(hyst[1], 6 + (0.5 - 0) / 0.6, accuracy: 1e-6)
  }

  // MARK: - Frequency and amplitude measurements

  func testFrequencyByZeroCrossingAndFFTWithinHalfAPercent() throws {
    for f in [47.3, 5.1, 1234.5] {
      let rate = f > 500 ? 48_000.0 : 1000
      let s = sampled(rate: rate, duration: f > 500 ? 0.25 : 2) { 1.5 * sin(2 * .pi * f * $0 + 0.3) + 0.2 }
      let m = ScopeEngine.measure(values: s.values, times: s.times, sampleRate: rate)
      let zc = try XCTUnwrap(m.frequencyZeroCrossing)
      let fft = try XCTUnwrap(m.frequencyFFT)
      XCTAssertEqual(zc / f, 1, accuracy: 0.005, "zero crossing at \(f) Hz")
      XCTAssertEqual(fft / f, 1, accuracy: 0.005, "FFT peak at \(f) Hz")
      XCTAssertEqual(try XCTUnwrap(m.period) * f, 1, accuracy: 0.005)
    }
  }

  func testZeroCrossingUsesTheSensorsOwnTimestamps() throws {
    // 60 Hz sampled at a jittery ~1 kHz: the values are taken at the true (jittered) times.
    var rng = ScopeTestRandom(seed: 11)
    var t = 0.0
    var values: [Float] = []
    var times: [Double] = []
    while t < 2 {
      times.append(t)
      values.append(Float(sin(2 * .pi * 60 * t)))
      t += 0.001 * (1 + 0.2 * (rng.uniform() - 0.5))
    }
    let zc = try XCTUnwrap(ScopeEngine.zeroCrossingFrequency(values: values, times: times))
    XCTAssertEqual(zc / 60, 1, accuracy: 0.002)
  }

  func testPeakToPeakAndRMSOfKnownWaveforms() throws {
    let rate = 10_000.0
    // Sine: amplitude 2, offset 0.5, whole periods.
    let sine = sampled(rate: rate, duration: 1) { 2 * sin(2 * .pi * 10 * $0) + 0.5 }
    let ms = ScopeEngine.measure(values: sine.values, times: sine.times, sampleRate: rate)
    XCTAssertEqual(try XCTUnwrap(ms.peakToPeak), 4, accuracy: 1e-3)
    XCTAssertEqual(try XCTUnwrap(ms.mean), 0.5, accuracy: 1e-4)
    XCTAssertEqual(try XCTUnwrap(ms.rms), (0.25 + 2).squareRoot(), accuracy: 1e-4)
    XCTAssertEqual(try XCTUnwrap(ms.acRMS), 2.squareRoot(), accuracy: 1e-4)
    XCTAssertEqual(try XCTUnwrap(ms.minimum), -1.5, accuracy: 1e-3)
    XCTAssertEqual(try XCTUnwrap(ms.maximum), 2.5, accuracy: 1e-3)
    // Square ±1.
    let square = sampled(rate: rate, duration: 1) { sin(2 * .pi * 10 * $0 + 0.01) >= 0 ? 1 : -1 }
    let mq = ScopeEngine.measure(values: square.values, times: square.times, sampleRate: rate)
    XCTAssertEqual(try XCTUnwrap(mq.peakToPeak), 2, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(mq.rms), 1, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(mq.frequencyZeroCrossing), 10, accuracy: 0.05)
    // Triangle of amplitude 1: RMS 1/√3.
    let tri = sampled(rate: rate, duration: 1) { t in
      let p = (t * 10).truncatingRemainder(dividingBy: 1)
      return p < 0.5 ? 4 * p - 1 : 3 - 4 * p
    }
    let mt = ScopeEngine.measure(values: tri.values, times: tri.times, sampleRate: rate)
    XCTAssertEqual(try XCTUnwrap(mt.rms), 1 / 3.0.squareRoot(), accuracy: 1e-3)
    XCTAssertEqual(try XCTUnwrap(mt.peakToPeak), 2, accuracy: 1e-3)
    // Empty and flat inputs never trap.
    XCTAssertEqual(ScopeEngine.measure(values: [], times: [], sampleRate: 100).count, 0)
    let flat = ScopeEngine.measure(values: [Float](repeating: 3, count: 100), times: (0..<100).map(Double.init), sampleRate: 1)
    XCTAssertEqual(flat.peakToPeak, 0)
    XCTAssertNil(flat.frequencyZeroCrossing)
    XCTAssertNil(flat.frequencyFFT)
  }

  // MARK: - Decimation, roll, XY

  func testDecimationKeepsPeaks() {
    let n = 100_000
    var values = (0..<n).map { Float(0.1 * sin(Double($0) * 0.001)) }
    values[12_345] = 10
    values[67_890] = -7
    let times = (0..<n).map { Double($0) * 1e-4 }
    let columns = ScopeEngine.decimate(values: values, times: times, window: 0...(Double(n) * 1e-4), columns: 300)
    XCTAssertEqual(columns.compactMap { $0?.maximum }.max(), 10)
    XCTAssertEqual(columns.compactMap { $0?.minimum }.min(), -7)
    XCTAssertEqual(columns.compactMap { $0?.count }.reduce(0, +), n, "every sample lands in exactly one column")
    let trace = ScopeEngine.trace(values: values, times: times, window: 0...(Double(n) * 1e-4), columns: 300)
    XCTAssertLessThanOrEqual(trace.count, 600)
    XCTAssertEqual(trace.map(\.y).max(), 10)
    XCTAssertEqual(trace.map(\.y).min(), -7)
    XCTAssertEqual(trace.map(\.x), trace.map(\.x).sorted(), "decimated trace stays in time order")
  }

  func testRollTraceOrderingAndWindow() {
    let s = sampled(rate: 100, duration: 10) { $0 }  // value = time
    let end = 9.99
    let roll = ScopeEngine.rollTrace(values: s.values, times: s.times, end: end, span: 5, columns: 1000)
    XCTAssertFalse(roll.isEmpty)
    XCTAssertEqual(roll.map(\.x), roll.map(\.x).sorted(), "oldest at the left, newest at the right")
    XCTAssertEqual(Double(roll.last?.x ?? 0), 1, accuracy: 1e-6, "the newest sample sits at the right edge")
    XCTAssertEqual(Double(roll.last?.y ?? 0), end, accuracy: 1e-4)
    XCTAssertGreaterThanOrEqual(Double(roll.first?.y ?? 0), end - 5 - 0.011, "nothing older than the window")
    // Irregular stream: sample-and-hold steps, held up to the right edge.
    let held = ScopeEngine.rollTrace(values: [1, 2, 3], times: [6, 7.5, 8], end: 10, span: 5, columns: 1000, hold: true)
    XCTAssertEqual(held.map(\.y), [1, 1, 2, 2, 3, 3])
    XCTAssertEqual(Double(held.last?.x ?? 0), 1, accuracy: 1e-6)
    XCTAssertEqual(held.map(\.x), held.map(\.x).sorted())
  }

  func testXYPairsSamplesByTimestamp() {
    // X at 100 Hz, Y = 2t at 50 Hz with a 3 ms offset (its own clock).
    let x = sampled(rate: 100, duration: 2) { sin($0) }
    let y = sampled(rate: 50, duration: 2, start: 0.003) { 2 * $0 }
    let pairs = ScopeEngine.pairXY(x: x, y: y, window: 0.5...1.5, tolerance: 0.03)
    XCTAssertEqual(pairs.count, 101)
    for p in pairs {
      // Recover x's time from its value, then Y must be 2t there (interpolated exactly).
      let t = asin(Double(p.x))
      XCTAssertEqual(Double(p.y), 2 * t, accuracy: 1e-4)
    }
    // A gap in Y longer than the tolerance drops those X samples instead of pairing stale values.
    var gappy = y
    let keep = gappy.times.indices.filter { gappy.times[$0] < 1.0 || gappy.times[$0] > 1.3 }
    gappy = (keep.map { y.values[$0] }, keep.map { y.times[$0] })
    let dropped = ScopeEngine.pairXY(x: x, y: gappy, window: 0.5...1.5, tolerance: 0.03)
    XCTAssertLessThan(dropped.count, pairs.count - 20)
    // Irregular Y is held.
    let held = ScopeEngine.pairXY(
      x: x, y: (values: [5, 7], times: [0.2, 1.0]), window: 0.5...1.5, tolerance: 0.01, holdY: true)
    XCTAssertEqual(held.count, 101)
    XCTAssertTrue(held.allSatisfy { $0.y == 5 || $0.y == 7 })
    XCTAssertEqual(held.first?.y, 5)
    XCTAssertEqual(held.last?.y, 7)
  }

  // MARK: - Math and coupling

  func testMathOperations() throws {
    var sum = ScopeEngine.MathProcessor(operation: .sum)
    XCTAssertEqual(sum.process(t: 0, a: 2, b: 3), 5)
    var diff = ScopeEngine.MathProcessor(operation: .difference)
    XCTAssertEqual(diff.process(t: 0, a: 2, b: 3), -1)
    var product = ScopeEngine.MathProcessor(operation: .product)
    XCTAssertEqual(product.process(t: 0, a: 2, b: 3), 6)
    var magnitude = ScopeEngine.MathProcessor(operation: .magnitude)
    XCTAssertEqual(try XCTUnwrap(magnitude.process(t: 0, a: 3, b: 4, c: 12)), 13, accuracy: 1e-6)
    XCTAssertNil(sum.process(t: 1, a: 1, b: nil), "a missing B gives no sample")
    // d/dt of 3t + 1 is 3; ∫ 2t dt over 0…1 is 1 (trapezoids are exact for straight lines).
    var d = ScopeEngine.MathProcessor(operation: .derivative)
    var integral = ScopeEngine.MathProcessor(operation: .integral)
    var lastD: Float?
    var lastI: Float?
    for k in 0...100 {
      let t = Double(k) / 100
      lastD = d.process(t: t, a: Float(3 * t + 1)) ?? lastD
      lastI = integral.process(t: t, a: Float(2 * t))
    }
    XCTAssertEqual(try XCTUnwrap(lastD), 3, accuracy: 1e-3)
    XCTAssertEqual(try XCTUnwrap(lastI), 1, accuracy: 1e-5)
    XCTAssertEqual(ScopeEngine.MathOperation.product.unit("g", "g"), "g²")
    XCTAssertEqual(ScopeEngine.MathOperation.derivative.unit("µT", ""), "µT/s")
    XCTAssertEqual(ScopeEngine.MathOperation.magnitude.inputs, 3)
  }

  func testHighPassRemovesDCAndPassesTheBandOnIrregularSamples() {
    // DC 50 (Earth field) plus a 20 Hz tone, sampled irregularly around 1 kHz.
    var hp = ScopeEngine.OnePoleHighPass(cornerHz: 0.5)
    var rng = ScopeTestRandom(seed: 5)
    var t = 0.0
    var tail: [Double] = []
    while t < 20 {
      let y = hp.process(50 + sin(2 * .pi * 20 * t), at: t)
      if t > 15 { tail.append(y) }
      t += 0.001 * (1 + 0.3 * (rng.uniform() - 0.5))
    }
    let mean = tail.reduce(0, +) / Double(tail.count)
    let peak = tail.map(abs).max() ?? 0
    XCTAssertEqual(mean, 0, accuracy: 0.01, "the steady part is gone")
    XCTAssertEqual(peak, 1, accuracy: 0.03, "20 Hz is far above the 0.5 Hz corner")
    // At the corner the gain is 1/√2.
    var corner = ScopeEngine.OnePoleHighPass(cornerHz: 2)
    var out: [Double] = []
    for k in 0..<20_000 {
      let tt = Double(k) * 1e-3
      let y = corner.process(sin(2 * .pi * 2 * tt), at: tt)
      if tt > 10 { out.append(y) }
    }
    XCTAssertEqual(out.map(abs).max() ?? 0, 1 / 2.0.squareRoot(), accuracy: 0.02)
    XCTAssertEqual(ScopeEngine.acCorner(sampleRate: 100), 2, accuracy: 1e-12)
    XCTAssertEqual(ScopeEngine.acCorner(sampleRate: 48_000), 10)
    XCTAssertEqual(ScopeEngine.acCorner(sampleRate: 1), 0.05)
  }

  // MARK: - Scales, timebase, aliasing

  func testOneTwoFiveScalesAndTimebaseLimits() {
    XCTAssertEqual(ScopeEngine.timebases.count, 19)
    XCTAssertEqual(ScopeEngine.timebases.first ?? 0, 10e-6, accuracy: 1e-18)
    XCTAssertEqual(ScopeEngine.timebases.last, 10)
    XCTAssertEqual(ScopeEngine.timebases[3], 1e-4, "10, 20, 50 µs, then 100 µs")
    // One sample per division at the stream's rate.
    XCTAssertEqual(ScopeEngine.minimumTimebase(sampleRate: 48_000), 50e-6, accuracy: 1e-15)
    XCTAssertEqual(ScopeEngine.minimumTimebase(sampleRate: 100), 0.01, accuracy: 1e-15)
    XCTAssertEqual(ScopeEngine.minimumTimebase(sampleRate: 99.8), 0.02, accuracy: 1e-15)
    XCTAssertEqual(ScopeEngine.minimumTimebase(sampleRate: nil), 0.1)
    let range = ScopeEngine.timebaseRange(rates: [100, nil], histories: [30, 120])
    XCTAssertEqual(range.lowerBound, 0.01, accuracy: 1e-15)
    XCTAssertEqual(range.upperBound, 10)
    XCTAssertEqual(ScopeEngine.clampTimebase(1e-5, to: range), 0.01, accuracy: 1e-15)
    XCTAssertEqual(ScopeEngine.clampTimebase(0.3, to: range), 0.2, accuracy: 1e-15)
    XCTAssertEqual(ScopeEngine.nice125(atLeast: 0.33), 0.5)
    XCTAssertEqual(ScopeEngine.snapScale(0.7, unit: "µT"), 0.5)
    let fit = ScopeEngine.autoScale(minimum: -3, maximum: 5, unit: "µT")
    XCTAssertEqual(fit.unitsPerDiv, 2)
    XCTAssertEqual(fit.reference, 1)
    XCTAssertEqual(ScopeEngine.boxcarDecimate([1, 3, 5, 7, 9], factor: 2), [2, 6])
  }

  func testAliasNotesForMainsOnTheMagnetometer() throws {
    let notes = ScopeEngine.aliasNotes(sources: [("60 Hz mains", 60), ("120 Hz", 120)], sampleRate: 99.8)
    let mains = try XCTUnwrap(notes.first { $0.frequency == 60 })
    XCTAssertEqual(mains.alias, 39.8, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(notes.first { $0.frequency == 120 }).alias, 20.2, accuracy: 1e-9)
    XCTAssertTrue(ScopeEngine.aliasNotes(sources: [("60 Hz", 60)], sampleRate: 48_000).isEmpty)
    XCTAssertEqual(ScopeEngine.mainsFrequency(region: "US"), 60)
    XCTAssertEqual(ScopeEngine.mainsFrequency(region: "IN"), 50)
    XCTAssertEqual(ScopeEngine.mainsFrequency(region: "de"), 50)
  }

  // MARK: - Streams, presets, settings, CSV

  func testStreamQueriesResolveByMeaning() {
    typealias C = ScopeEngine.StreamCandidate
    let sim = [
      C(id: "accel.x", label: "Accelerometer X", group: StreamGroup.motion, unit: "g", rate: 100),
      C(id: "gyro.x", label: "Gyroscope X", group: StreamGroup.motion, unit: "rad/s", rate: 100),
      C(id: "mag.x", label: "Magnetic field X", group: StreamGroup.magnetometer, unit: "µT", rate: 100),
      C(id: "mag.norm", label: "Magnetic field |B|", group: StreamGroup.magnetometer, unit: "µT", rate: 100),
    ]
    let live =
      sim + [
        C(id: "accel.user.x", label: "User acceleration X", group: StreamGroup.motion, unit: "g", rate: 100),
        C(id: "gravity.x", label: "Gravity X", group: StreamGroup.motion, unit: "g", rate: 100),
        C(id: "mag.raw.x", label: "Raw magnetometer X", group: StreamGroup.magnetometer, unit: "µT", rate: 100),
        C(id: "mag.raw.norm", label: "Raw magnetometer |B|", group: StreamGroup.magnetometer, unit: "µT", rate: 100),
      ]
    let accelX = ScopeEngine.StreamQuery(
      group: StreamGroup.motion, axis: "x", any: ["accel", "acceleration"], prefer: ["user"], avoid: ["gravity", "raw"])
    XCTAssertEqual(ScopeEngine.resolve(accelX, in: sim), "accel.x")
    XCTAssertEqual(ScopeEngine.resolve(accelX, in: live), "accel.user.x")
    let magX = ScopeEngine.StreamQuery(group: StreamGroup.magnetometer, axis: "x", prefer: ["calibrated"], avoid: ["raw"])
    XCTAssertEqual(ScopeEngine.resolve(magX, in: live), "mag.x")
    let norm = ScopeEngine.StreamQuery(group: StreamGroup.magnetometer, any: ["norm", "|b|"], avoid: ["raw"])
    XCTAssertEqual(ScopeEngine.resolve(norm, in: live), "mag.norm")
    let gravity = ScopeEngine.StreamQuery(group: StreamGroup.motion, axis: "x", any: ["gravity"])
    XCTAssertNil(ScopeEngine.resolve(gravity, in: sim))
    XCTAssertEqual(ScopeEngine.resolve(gravity, in: live), "gravity.x")
    // The three strongest Bluetooth radios, by their latest RSSI.
    let ble = [
      C(id: "ble.A.rssi", label: "Watch RSSI", group: StreamGroup.bluetooth, unit: "dBm", rate: 0, latest: -70),
      C(id: "ble.B.rssi", label: "Laptop RSSI", group: StreamGroup.bluetooth, unit: "dBm", rate: 0, latest: -48),
      C(id: "ble.C.rssi", label: "TV RSSI", group: StreamGroup.bluetooth, unit: "dBm", rate: 0, latest: -60),
    ]
    let picks = (0..<4).map {
      ScopeEngine.resolve(ScopeEngine.StreamQuery(group: StreamGroup.bluetooth, any: ["rssi"], rank: .strongest($0)), in: ble)
    }
    XCTAssertEqual(picks, ["ble.B.rssi", "ble.C.rssi", "ble.A.rssi", nil])
    let fastest = ScopeEngine.StreamQuery(group: StreamGroup.audio, avoid: ["level"], rank: .fastest)
    let audio = [
      C(id: "mic.level", label: "Microphone level", group: StreamGroup.audio, unit: "dBFS", rate: 46.875),
      C(id: "mic.left", label: "Microphone", group: StreamGroup.audio, unit: "FS", rate: 48_000),
    ]
    XCTAssertEqual(ScopeEngine.resolve(fastest, in: audio), "mic.left")
    XCTAssertEqual(ScopeEngine.sensor(for: "mag.x"), .magnetometer)
    XCTAssertEqual(ScopeEngine.sensor(for: "accel.user.z"), .motion)
    XCTAssertEqual(ScopeEngine.sensor(for: "ble.X.rssi"), .bluetooth)
    XCTAssertNil(ScopeEngine.sensor(for: "spin.fid"))
  }

  func testPresetsConfigureModesAndSensors() {
    XCTAssertEqual(ScopePreset.allCases.count, 11)
    var s = ScopeSettings()
    ScopePreset.seismograph.configure(&s)
    XCTAssertEqual(s.mode, .roll)
    XCTAssertEqual(s.timebase, 1)
    XCTAssertEqual(s.channels[0].coupling, .removeGravity)
    ScopePreset.compassXY.configure(&s)
    XCTAssertEqual(s.mode, .xy)
    XCTAssertEqual(s.xChannel, 0)
    XCTAssertEqual(s.yChannel, 1)
    ScopePreset.sound.configure(&s)
    XCTAssertEqual(s.timebase, 0.001)
    XCTAssertEqual(ScopePreset.sound.sensors, [.microphone])
    ScopePreset.vibration.configure(&s)
    XCTAssertTrue(s.math.enabled)
    XCTAssertEqual(s.math.operation, .magnitude)
    XCTAssertEqual(s.math.label, "|ω|")
    ScopePreset.bluetoothEMF.configure(&s)
    XCTAssertEqual(s.channels.prefix(3).compactMap { $0.query?.rank }, [.strongest(0), .strongest(1), .strongest(2)])
    XCTAssertTrue(ScopePreset.bluetoothEMF.caption.contains("no broadband RF power meter"))
    XCTAssertEqual(ScopePreset.spinFID.modelStreams, [.spinFID])
    XCTAssertEqual(ScopePreset(name: "Magnetic scope"), .magnetic)
    XCTAssertEqual(ScopePreset(name: "spin fid"), .spinFID)
    XCTAssertEqual(ScopePreset(name: "radio-iq"), .radioIQ)
    XCTAssertEqual(ScopePreset(name: "Light flicker (experimental)"), .lightFlicker)
    XCTAssertNil(ScopePreset(name: "teleporter"))
  }

  func testSettingsRoundTripAndTolerantDecoding() throws {
    var s = ScopeSettings()
    ScopePreset.magnetic.configure(&s)
    s.persistence = ScopeSettings.infinitePersistence
    s.cursors.mode = .both
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(ScopeSettings.self, from: data), s)
    let partial = Data(#"{"mode":"fft","timebase":-3,"xChannel":9,"persistence":1e9,"channels":[]}"#.utf8)
    let d = try JSONDecoder().decode(ScopeSettings.self, from: partial)
    XCTAssertEqual(d.mode, .fft)
    XCTAssertEqual(d.timebase, ScopeSettings().timebase, "invalid timebase falls back")
    XCTAssertEqual(d.xChannel, 3, "clamped")
    XCTAssertEqual(d.persistence, ScopeSettings.infinitePersistence)
    XCTAssertEqual(d.channels.count, 4)
  }

  func testCSVOfTheVisibleWindow() {
    let csv = ScopeEngine.csv(
      [
        ScopeEngine.CSVColumn(header: "CH1 Magnetic field X", unit: "µT", times: [10, 10.01], values: [1.5, -2]),
        ScopeEngine.CSVColumn(header: "CH2 a, b", unit: "g", times: [10.005], values: [0.25]),
      ], origin: 10)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    XCTAssertEqual(lines[0], "CH1 Magnetic field X time (s),CH1 Magnetic field X (µT),\"CH2 a, b time (s)\",\"CH2 a, b (g)\"")
    XCTAssertEqual(lines[1], "0.000000,1.5,0.005000,0.25")
    XCTAssertEqual(lines[2], "0.010000,-2,,")
    XCTAssertEqual(lines.count, 4)
  }

  // MARK: - Probe streams

  func testProbeStreamsPublishTheFIDAndIQWithoutReplacingOthers() throws {
    let registry = StreamRegistry()
    let probes = ScopeProbeStreams()
    let t0 = SignalClock.now()
    probes.ensure([.spinFID, .radioIQ], registry: registry)
    let fid = try XCTUnwrap(registry.stream(ScopeProbeStreams.fidID))
    XCTAssertEqual(fid.provenance, .model)
    XCTAssertEqual(fid.group, StreamGroup.spin)
    XCTAssertNotNil(registry.stream(ScopeProbeStreams.iID))
    probes.pump(now: t0 + 0.45, fieldTesla: 50e-6)
    let snap = fid.ring.snapshot()
    XCTAssertGreaterThan(snap.count, 3000)
    let f = try XCTUnwrap(ScopeEngine.fftPeakFrequency(values: Array(snap.values.prefix(2048)), sampleRate: ScopeProbeStreams.fidRate))
    // Water protons at 50 µT: 2128.8 Hz (true pitch).
    XCTAssertEqual(f / SpinSpecies.protonWater.larmorHz(field: 50e-6), 1, accuracy: 0.005)
    let i = try XCTUnwrap(registry.stream(ScopeProbeStreams.iID)).ring.snapshot()
    XCTAssertEqual(Double(i.count), 0.45 * ScopeProbeStreams.iqDisplayRate, accuracy: 3)
    if case .slowed(let k) = probes.radioTimeMapping {
      XCTAssertEqual(k, ScopeProbeStreams.edgeSampleRate / 200, accuracy: 1e-6)
    } else {
      XCTFail("I/Q is κ-slowed")
    }
    probes.stopAll(registry: registry)
    XCTAssertNil(registry.stream(ScopeProbeStreams.fidID))
    // Someone else's spin.fid is never replaced.
    let theirs = SignalStream(id: ScopeProbeStreams.fidID, label: "Spin tab FID", unit: "V", nominalRate: 2000, provenance: .model, group: StreamGroup.spin)
    registry.register(theirs)
    probes.ensure([.spinFID], registry: registry)
    XCTAssertTrue(registry.stream(ScopeProbeStreams.fidID) === theirs)
    XCTAssertFalse(probes.owns(ScopeProbeStreams.fidID))
  }

  // MARK: - Time–frequency plumbing

  func testTimeFrequencyImageOfAChirpHasExactTimeMarginal() {
    let rate = 1000.0
    let s = sampled(rate: rate, duration: 1) { t in sin(2 * .pi * (50 * t + 150 * t * t)) }
    let wv = ScopeModel.computeTF(values: s.values, sampleRate: rate, mode: .wignerVille)
    XCTAssertEqual(wv.width, 256)
    XCTAssertEqual(wv.height, 256)
    XCTAssertEqual(wv.pixels.count, 256 * 256 * 4)
    XCTAssertLessThan(wv.m1Error, 1e-9, "Wigner–Ville time marginal = |z(t)|²")
    let sg = ScopeModel.computeTF(values: s.values, sampleRate: rate, mode: .spectrogram)
    XCTAssertGreaterThan(sg.m1Error, 1e-6, "the spectrogram's marginals are smoothed")
  }

  // MARK: - The model end to end

  func testModelTriggersMeasuresAndClampsTheTimebase() throws {
    let app = makeApp()
    let stream = SignalStream(
      id: "test.tone", label: "Test tone", unit: "µT", nominalRate: 1000, provenance: .sim, group: StreamGroup.patch,
      capacity: 4000)
    app.streams.register(stream)
    let now = SignalClock.now()
    let s = sampled(rate: 1000, duration: 2, start: now - 2) { 3 * sin(2 * .pi * 25 * $0) }
    stream.ring.append(contentsOf: s.values, times: s.times)
    let model = ScopeModel(owner: "scope.test", persistent: false, fixedStreams: ["test.tone"])
    model.appear(app: app)
    defer { model.disappear() }
    // 1 kHz allows 1 ms/div at the fastest; 10 µs is refused.
    model.setTimebase(10e-6)
    XCTAssertEqual(model.timebase, 0.001, accuracy: 1e-12)
    model.setTimebase(0.01)
    model.mutate { s in
      s.trigger.level = 0
      s.trigger.slope = .rising
      s.trigger.source = 0
    }
    model.tick()
    let window = model.displayWindow
    XCTAssertEqual(window.upperBound - window.lowerBound, 0.1, accuracy: 1e-9)
    // The trigger instant sits on the centre line: a rising zero of the tone.
    let mid = (window.lowerBound + window.upperBound) / 2
    XCTAssertEqual(sin(2 * .pi * 25 * mid), 0, accuracy: 0.01)
    XCTAssertGreaterThan(cos(2 * .pi * 25 * mid), 0)
    model.mutate { $0.measureChannel = 0 }
    model.tick()
    let m = try XCTUnwrap(model.readout.measurements[0])
    XCTAssertEqual(try XCTUnwrap(m.frequencyZeroCrossing), 25, accuracy: 0.125)
    XCTAssertEqual(try XCTUnwrap(m.peakToPeak), 6, accuracy: 0.05)
    XCTAssertFalse(model.export.isEmpty)
    // Stop freezes; Run resumes.
    model.toggleRun()
    XCTAssertFalse(model.running)
    model.toggleRun()
    XCTAssertTrue(model.running)
    // Slow timebases roll.
    model.setTimebase(0.5)
    XCTAssertEqual(model.settings.mode, .roll)
  }

  func testInvertAndACCouplingOnATrack() {
    let stream = SignalStream(id: "test.dc", label: "DC plus tone", unit: "µT", nominalRate: 100, provenance: .sim, group: StreamGroup.patch)
    let s = sampled(rate: 100, duration: 30) { 48 + sin(2 * .pi * 5 * $0) }
    stream.ring.append(contentsOf: s.values, times: s.times)
    let track = ScopeTrack(stream: stream, coupling: .dc, invert: false, gravity: nil)
    track.ingest()
    XCTAssertEqual(Double(track.values.last ?? 0), 48 + sin(2 * .pi * 5 * s.times.last!), accuracy: 1e-4)
    track.configure(coupling: .ac, invert: false, gravity: nil)
    let ac = track.values
    let tail = ac.suffix(500).map(Double.init)
    XCTAssertEqual(tail.reduce(0, +) / Double(tail.count), 0, accuracy: 0.05, "AC removes the 48 µT")
    let swing = (tail.max() ?? 0) - (tail.min() ?? 0)
    XCTAssertGreaterThan(swing, 1.6, "the 5 Hz tone passes the 2 Hz corner")
    XCTAssertLessThan(swing, 2.1)
    track.configure(coupling: .ac, invert: true, gravity: nil)
    XCTAssertEqual(track.values, ac.map { -$0 }, "invert flips the coupled trace")
  }

  // MARK: - Review fixes

  func testAutoFreeRunsWhenTheTriggerSourceHasNoSignal() throws {
    let app = makeApp()
    let stream = SignalStream(
      id: "test.free", label: "Free-run tone", unit: "µT", nominalRate: 1000, provenance: .sim, group: StreamGroup.patch,
      capacity: 4000)
    app.streams.register(stream)
    let now = SignalClock.now()
    let s = sampled(rate: 1000, duration: 2, start: now - 2) { sin(2 * .pi * 25 * $0) }
    stream.ring.append(contentsOf: s.values, times: s.times)
    let model = ScopeModel(owner: "scope.test.free", persistent: false, fixedStreams: ["test.free"])
    model.appear(app: app)
    defer { model.disappear() }
    model.setTimebase(0.01)
    // CH3 is off: Auto free-runs on CH1 instead of reporting NO SIGNAL.
    model.mutate { s in
      s.trigger.source = 2
      s.trigger.mode = .auto
    }
    model.tick()
    XCTAssertEqual(model.readout.status, .auto)
    XCTAssertEqual(model.displayWindow.upperBound, try XCTUnwrap(s.times.last), accuracy: 1e-9)
    // Normal waits (and says so) instead.
    model.mutate { $0.trigger.mode = .normal }
    Thread.sleep(forTimeInterval: 0.25)
    model.tick()
    XCTAssertEqual(model.readout.status, .waiting)
  }

  func testOpenInScopeResumesAStoppedScope() throws {
    let app = makeApp()
    let stream = SignalStream(
      id: "test.resume", label: "Resume tone", unit: "µT", nominalRate: 200, provenance: .sim, group: StreamGroup.patch,
      capacity: 2000)
    app.streams.register(stream)
    let now = SignalClock.now()
    let s = sampled(rate: 200, duration: 2, start: now - 3) { sin(2 * .pi * 5 * $0) }
    stream.ring.append(contentsOf: s.values, times: s.times)
    let model = ScopeModel(owner: "scope.test.resume", persistent: false)
    model.app = app
    app.openScope(["test.resume"])
    model.applyPendingRequest()
    XCTAssertEqual(model.settings.channels[0].stream, "test.resume")
    model.setTimebase(0.5)
    XCTAssertEqual(model.settings.mode, .roll)
    model.tick()
    model.toggleRun()
    let frozen = model.displayWindow.upperBound
    XCTAssertEqual(frozen, try XCTUnwrap(s.times.last), accuracy: 1e-9)
    // A new "Open in Scope" runs again and lets go of the frozen window.
    app.openScope(["test.resume"])
    model.applyPendingRequest()
    XCTAssertTrue(model.running)
    Thread.sleep(forTimeInterval: 0.01)
    model.tick()
    XCTAssertGreaterThan(model.displayWindow.upperBound, frozen + 0.3)
  }

  func testAVanishedProbeStreamIsFoundAgainByMeaning() {
    let app = makeApp()
    let a = SignalStream(id: "test.probe.a", label: "Probe A", unit: "dBm", nominalRate: 0, provenance: .sim, group: StreamGroup.patch)
    let b = SignalStream(id: "test.probe.b", label: "Probe B", unit: "dBm", nominalRate: 0, provenance: .sim, group: StreamGroup.patch)
    app.streams.register([a, b])
    let model = ScopeModel(owner: "scope.test.resolve", persistent: false, fixedStreams: ["test.gone", "test.probe.a"])
    model.app = app
    model.mutate { s in
      s.channels[0].query = ScopeEngine.StreamQuery(group: StreamGroup.patch, any: ["probe"])
    }
    model.resolveChannels(force: true)
    // CH1's stream is gone; CH2 already shows A, so CH1 takes B.
    XCTAssertEqual(model.settings.channels[0].stream, "test.probe.b")
    XCTAssertEqual(model.settings.channels[1].stream, "test.probe.a")
    // A channel whose stream is still registered is left alone.
    app.streams.register(SignalStream(id: "test.probe.0", label: "Probe 0", unit: "dBm", nominalRate: 0, provenance: .sim, group: StreamGroup.patch))
    model.resolveChannels(force: true)
    XCTAssertEqual(model.settings.channels[0].stream, "test.probe.b")
  }

  func testDamagedSettingsAreSanitizedOnLoad() throws {
    var bad = ScopeSettings()
    bad.trigger.source = 9
    bad.cursors.channel = -3
    bad.cursors.t1 = 40
    bad.math.a = .channel(7)
    bad.channels[2].unitsPerDiv = 0
    bad.channels[1].position = -12
    let decoded = try JSONDecoder().decode(ScopeSettings.self, from: JSONEncoder().encode(bad))
    XCTAssertEqual(decoded.trigger.source, 4)
    XCTAssertEqual(decoded.cursors.channel, 0)
    XCTAssertEqual(decoded.cursors.t1, 10)
    XCTAssertEqual(decoded.math.a, .channel(3))
    XCTAssertEqual(decoded.channels[2].unitsPerDiv, 1)
    XCTAssertEqual(decoded.channels[1].position, -4)
    XCTAssertNil(ScopePreset(name: ""))
    XCTAssertNil(ScopePreset(name: "—"))
  }

  func testCursorReadoutFollowsTheCursorModeAndDisplayMode() throws {
    let app = makeApp()
    let stream = SignalStream(id: "test.cursor", label: "Cursor tone", unit: "µT", nominalRate: 1000, provenance: .sim, group: StreamGroup.patch)
    app.streams.register(stream)
    let model = ScopeModel(owner: "scope.test.cursor", persistent: false, fixedStreams: ["test.cursor"])
    model.app = app
    model.setTimebase(0.01)
    model.mutate { s in
      s.mode = .yt
      s.channels[0].unitsPerDiv = 2
      s.cursors = ScopeCursors(mode: .time, t1: 2, t2: 7, y1: 1.5, y2: -0.5, channel: 0)
    }
    var r = try XCTUnwrap(model.cursorReadout)
    XCTAssertEqual(try XCTUnwrap(r.dt), 0.05, accuracy: 1e-12)
    XCTAssertEqual(try XCTUnwrap(r.frequency), 20, accuracy: 1e-9)
    XCTAssertNil(r.dy)
    model.mutate { $0.cursors.mode = .amplitude }
    r = try XCTUnwrap(model.cursorReadout)
    XCTAssertNil(r.dt)
    XCTAssertEqual(try XCTUnwrap(r.dy), 4, accuracy: 1e-12)
    XCTAssertEqual(r.unit, "µT")
    model.setMode(.fft)
    XCTAssertNil(model.cursorReadout, "cursors measure YT and Roll only")
  }

  func testAnalysisModesGiveTheTimebaseBackOnTheWayOut() {
    let app = makeApp()
    let stream = SignalStream(id: "test.slow", label: "Slow", unit: "µT", nominalRate: 100, provenance: .sim, group: StreamGroup.patch)
    app.streams.register(stream)
    let model = ScopeModel(owner: "scope.test.restore", persistent: false, fixedStreams: ["test.slow"])
    model.app = app
    model.setTimebase(0.05)
    model.setMode(.fft)
    model.tick()
    // 1024 samples at 100 Hz need 10.24 s: the window grows to 2 s/div …
    XCTAssertEqual(model.timebase, 2, accuracy: 1e-12)
    model.setMode(.spectrogram)
    // … and YT gets its 50 ms/div back.
    model.setMode(.yt)
    XCTAssertEqual(model.timebase, 0.05, accuracy: 1e-12)
    // A timebase the user turns while analysing is kept.
    model.setMode(.fft)
    Thread.sleep(forTimeInterval: 0.01)
    model.tick()
    model.setTimebase(5)
    model.setMode(.xy)
    XCTAssertEqual(model.timebase, 5, accuracy: 1e-12)
  }

  func testTwoChannelsDoNotResolveToTheSameStream() {
    let app = makeApp()
    app.streams.register(
      SignalStream(id: "test.rtt", label: "Round-trip time", unit: "ms", nominalRate: 1, provenance: .sim, group: StreamGroup.network))
    let model = ScopeModel(owner: "scope.test.unique", persistent: false, fixedStreams: ["test.none"])
    model.app = app
    model.mutate { s in
      s.channels[0] = ScopeChannel(query: ScopeEngine.StreamQuery(group: StreamGroup.network, any: ["rtt"], prefer: ["wifi"]))
      s.channels[1] = ScopeChannel(query: ScopeEngine.StreamQuery(group: StreamGroup.network, any: ["rtt"], prefer: ["cell"]))
    }
    model.resolveChannels(force: true)
    XCTAssertEqual(model.settings.channels[0].stream, "test.rtt")
    XCTAssertNil(model.settings.channels[1].stream, "the cellular RTT waits for its own stream")
  }

  // MARK: - Second review

  /// Registers streams in `app` the way the live builder names them.
  private func register(_ app: AppModel, _ specs: [(id: String, label: String, group: String, unit: String)]) {
    app.streams.register(
      specs.map { SignalStream(id: StreamID($0.id), label: $0.label, unit: $0.unit, nominalRate: 100, provenance: .sim, group: $0.group) })
  }

  func testOpenInScopeWithAProbePlacesStreamsOnTheChannelsThatAskForThem() throws {
    let app = makeApp()
    register(
      app,
      [
        ("mag.x", "Magnetic field X", StreamGroup.magnetometer, "µT"), ("mag.y", "Magnetic field Y", StreamGroup.magnetometer, "µT"),
        ("mag.z", "Magnetic field Z", StreamGroup.magnetometer, "µT"), ("mag.norm", "Magnetic field |B|", StreamGroup.magnetometer, "µT"),
        ("ble.A.rssi", "Watch RSSI", StreamGroup.bluetooth, "dBm"), ("ble.B.rssi", "Laptop RSSI", StreamGroup.bluetooth, "dBm"),
        ("battery.level", "Battery level", StreamGroup.device, "%"),
      ])
    let model = ScopeModel(owner: "scope.test.place", persistent: false)
    model.app = app
    // "|B| in Scope" with the Magnetic probe: |B| lands on the probe's |B| trace (CH4); CH1 keeps
    // its AC-coupled X axis.
    app.openScope(["mag.norm"], preset: "Magnetic scope")
    model.applyPendingRequest()
    XCTAssertEqual(model.settings.channels.map(\.stream), ["mag.x", "mag.y", "mag.z", "mag.norm"])
    XCTAssertEqual(model.settings.channels[0].coupling, .ac)
    XCTAssertEqual(model.settings.channels[3].coupling, .dc)
    // Bluetooth / EMF with one radio and |B|: the radio on CH1, |B| on CH4 (not on CH2's dBm
    // band), and no radio drawn twice.
    app.openScope(["ble.B.rssi", "mag.norm"], preset: "Bluetooth / EMF")
    model.applyPendingRequest()
    let s = model.settings
    XCTAssertEqual(s.channels[0].stream, "ble.B.rssi")
    XCTAssertEqual(s.channels[3].stream, "mag.norm")
    XCTAssertEqual(s.channels[3].position, -3)
    let shown = s.channels.compactMap { $0.enabled ? $0.stream : nil }
    XCTAssertEqual(shown.count, Set(shown).count, "no stream twice: \(shown)")
    XCTAssertEqual(s.channels[1].stream, "ble.A.rssi", "CH2 takes the radio CH1 does not show")
    // A stream with no probe: DC, centered, auto-scaled; the probe's other traces and math go.
    app.openScope(["battery.level"])
    model.applyPendingRequest()
    let b = model.settings
    XCTAssertEqual(b.channels[0].stream, "battery.level")
    XCTAssertEqual(b.channels[0].coupling, .dc)
    XCTAssertEqual(b.channels[0].position, 0)
    XCTAssertTrue(b.channels[0].autoScale)
    XCTAssertEqual(b.channels.filter(\.enabled).count, 1)
    XCTAssertFalse(b.math.enabled)
    XCTAssertNil(b.preset)
    XCTAssertEqual(b.trigger.source, 0)
    // A stream that is not registered yet is still matched by its id within the probe's group.
    XCTAssertTrue(model.query(ScopeEngine.StreamQuery(group: StreamGroup.radio, any: ["radio.i"]), matches: "radio.i"))
    XCTAssertFalse(model.query(ScopeEngine.StreamQuery(group: StreamGroup.radio, any: ["radio.q"]), matches: "radio.i"))
    XCTAssertTrue(model.query(ScopeEngine.StreamQuery(group: StreamGroup.magnetometer, axis: "z"), matches: "mag.raw.z"))
  }

  func testTheSensorBehindAStreamFollowsItsRegisteredGroup() {
    XCTAssertNil(ScopeEngine.sensor(for: "gyro.tip.i", group: StreamGroup.spin), "Spin's simulated gyroscope tip is not the motion sensor")
    XCTAssertEqual(ScopeEngine.sensor(for: "gyro.tip.i"), .motion, "unregistered: by prefix")
    XCTAssertEqual(ScopeEngine.sensor(for: "uwb.distance", group: StreamGroup.radio), .uwb)
    XCTAssertNil(ScopeEngine.sensor(for: "radio.i", group: StreamGroup.radio))
    XCTAssertEqual(ScopeEngine.sensor(for: "battery.level", group: StreamGroup.device), .charging)
    XCTAssertEqual(ScopeEngine.sensor(for: "light.flicker", group: StreamGroup.light), .light)
  }

  func testTheTimeMappingChipFollowsWhatTheStreamsDeclare() {
    let app = makeApp()
    register(
      app,
      [
        ("test.real", "Real thing", StreamGroup.patch, "V"), ("test.kappa", "Spectrum Ex at z = 0 (κ-slowed)", StreamGroup.patch, "V"),
        ("test.electron", "Spin FID I · electron (dial B₀, slowed ×714)", StreamGroup.spin, "M₀"),
      ])
    let model = ScopeModel(owner: "scope.test.time", persistent: false, fixedStreams: ["test.real"])
    model.app = app
    XCTAssertEqual(model.timeNote, .known(.realTime))
    let slowed = ScopeModel(owner: "scope.test.time2", persistent: false, fixedStreams: ["test.real", "test.kappa"])
    slowed.app = app
    XCTAssertEqual(slowed.timeNote, .declared(badge: "κ-SLOWED", detail: "CH2, at its source"))
    let electron = ScopeModel(owner: "scope.test.time3", persistent: false, fixedStreams: ["test.electron"])
    electron.app = app
    XCTAssertEqual(electron.timeNote, .known(.slowed(factor: 714)))
    XCTAssertNil(ScopeModel.slowFactor(in: "slowed ×1.1 × 10⁴"))
    XCTAssertEqual(ScopeModel.slowFactor(in: "(slowed ×2.5)"), 2.5)
  }

  func testDecibelLevelsMeasureSpreadsInDBAndPowerAsAMeanOfPowers() throws {
    // −40 and −60 dBm: 20 dB apart; mean power 10·log₁₀((1e-4 + 1e-6)/2) mW = −42.97 dBm.
    XCTAssertEqual(try XCTUnwrap(ScopeEngine.powerMean([-40, -60])), 10 * log10((1e-4 + 1e-6) / 2), accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(ScopeEngine.powerMean([-50, -50, .nan])), -50, accuracy: 1e-9)
    XCTAssertNil(ScopeEngine.powerMean([]))
    XCTAssertEqual(ScopeEngine.differenceUnit("dBm"), "dB")
    XCTAssertEqual(ScopeEngine.differenceUnit("dBFS"), "dB")
    XCTAssertEqual(ScopeEngine.differenceUnit("µT"), "µT")
    XCTAssertEqual(ScopeFormat.scale(20, unit: "dBm"), "20 dB/div")
    // The model reports mean power, not the RMS of the numbers (which would read "+50 dBm").
    let app = makeApp()
    let rssi = SignalStream(id: "test.rssi", label: "Test RSSI", unit: "dBm", nominalRate: 0, provenance: .sim, group: StreamGroup.patch)
    app.streams.register(rssi)
    let now = SignalClock.now()
    rssi.ring.append(contentsOf: [-40, -60, -40, -60], times: [now - 0.8, now - 0.6, now - 0.4, now - 0.2])
    let model = ScopeModel(owner: "scope.test.db", persistent: false, fixedStreams: ["test.rssi"])
    model.appear(app: app)
    defer { model.disappear() }
    model.setTimebase(0.5)
    model.tick()
    let m = try XCTUnwrap(model.readout.measurements[0])
    XCTAssertEqual(try XCTUnwrap(m.rms), 10 * log10((1e-4 + 1e-6) / 2), accuracy: 1e-6)
    XCTAssertEqual(try XCTUnwrap(m.peakToPeak), 20, accuracy: 1e-6)
    model.mutate { $0.cursors.mode = .amplitude }
    XCTAssertEqual(model.cursorReadout?.unit, "dB")
  }

  func testSensorsStartedFromTheSourceListStopWhenTheSheetCloses() {
    let app = makeApp()
    let model = ScopeModel(owner: "scope.test.browse", persistent: false, fixedStreams: ["test.none"])
    model.appear(app: app)
    defer { model.disappear() }
    model.startSensorForPicking(.barometer)
    XCTAssertTrue(app.live.holders(of: .barometer).contains("scope.test.browse"))
    model.endBrowsing()
    XCTAssertFalse(app.live.holders(of: .barometer).contains("scope.test.browse"), "nothing shows it, so it stops")
  }

  // MARK: - Third review

  func testNetworkAndAirProbesStackTheirTracesAndWaitForNothingThatIsNeverPublished() {
    var s = ScopeSettings()
    ScopePreset.network.configure(&s)
    XCTAssertEqual(s.channels.filter(\.enabled).count, 2, "RTT and link quality; no cellular-only RTT channel")
    XCTAssertEqual(s.channels.prefix(2).map(\.position), [2, -2])
    ScopePreset.air.configure(&s)
    XCTAssertEqual(s.channels.prefix(2).map(\.position), [2, -2], "pressure above, altitude below")
    // With the live builder's network streams every enabled channel finds its stream.
    let app = makeApp()
    register(
      app,
      [
        ("net.rtt", "Round-trip time", StreamGroup.network, "ms"),
        ("net.quality", "Link quality (0 unknown … 3 good)", StreamGroup.network, "level"),
      ])
    let model = ScopeModel(owner: "scope.test.net", persistent: false)
    model.app = app
    model.applyPreset(.network, tapped: false)
    XCTAssertEqual(model.settings.channels.compactMap { $0.enabled ? $0.stream : nil }, ["net.rtt", "net.quality"])
    XCTAssertFalse((0..<4).contains { model.settings.channels[$0].enabled && !model.isShown($0) }, "no channel left waiting")
  }

  func testAliasNotesBelongToTheChannelThatAliases() throws {
    let app = makeApp()
    let mag = SignalStream(id: "test.mag.x", label: "Magnetic field X", unit: "µT", nominalRate: 100, provenance: .sim, group: StreamGroup.magnetometer)
    let mic = SignalStream(id: "test.mic", label: "Microphone", unit: "FS", nominalRate: 48_000, provenance: .sim, group: StreamGroup.audio)
    app.streams.register([mag, mic])
    let model = ScopeModel(owner: "scope.test.alias", persistent: false, fixedStreams: ["test.mag.x", "test.mic"])
    model.app = app
    model.tick()
    XCTAssertFalse(try XCTUnwrap(model.readout.channelAliasNotes[0]).isEmpty, "the magnetometer aliases mains")
    XCTAssertNil(model.readout.channelAliasNotes[1], "the microphone samples mains truthfully")
    XCTAssertTrue(model.aliasNotes(channel: 1).isEmpty)
    XCTAssertEqual(model.readout.aliasNotes, model.aliasNotes(channel: 0), "the chip lists the union")
  }

  func testAutoScaleBringsATriggerLevelTheTraceNeverReachesOntoTheTrace() throws {
    let app = makeApp()
    let stream = SignalStream(
      id: "test.field", label: "Field with hum", unit: "µT", nominalRate: 100, provenance: .sim, group: StreamGroup.patch,
      capacity: 1000)
    app.streams.register(stream)
    let now = SignalClock.now()
    let s = sampled(rate: 100, duration: 4, start: now - 4) { 48 + sin(2 * .pi * 5 * $0) }
    stream.ring.append(contentsOf: s.values, times: s.times)
    let model = ScopeModel(owner: "scope.test.level", persistent: false, fixedStreams: ["test.field"])
    model.app = app
    // DC: the default level 0 lies far below a 48 µT trace; the first refit puts it on the trace.
    model.tick()
    XCTAssertEqual(model.settings.trigger.level, 48, accuracy: 1.01)
    // A level the user puts on the trace is kept by later refits.
    model.mutate { $0.trigger.level = 48.5 }
    // Switching to AC leaves 48.5 µT far above the ±1 µT trace: the next refit recenters it.
    model.mutate { $0.channels[0].coupling = .ac }
    Thread.sleep(forTimeInterval: 0.55)
    model.tick()
    XCTAssertEqual(model.settings.channels[0].reference, 0, accuracy: 0.5)
    XCTAssertEqual(model.settings.trigger.level, model.settings.channels[0].reference, accuracy: 1e-12)
    XCTAssertLessThan(abs(model.settings.trigger.level), 0.5)
  }

  func testTheMeasuredRateIsTheSpacingTheSamplesHaveEvenWithGaps() throws {
    // An 8 kHz FID produced in 0.1 s blocks with 0.6 s stalls between them: samples ÷ seconds
    // reads about 1.1 kHz, below the 2.1 kHz line's Nyquist rate; the spacing is still 1/8000.
    var times: [Double] = []
    var values: [Float] = []
    var t0 = 0.0
    for _ in 0..<4 {
      for k in 0..<800 {
        let t = t0 + Double(k) / 8000
        times.append(t)
        values.append(Float(sin(2 * .pi * 2128.8 * t)))
      }
      t0 += 0.7
    }
    XCTAssertEqual(try XCTUnwrap(ScopeTrack.medianRate(times)), 8000, accuracy: 1e-6)
    XCTAssertLessThan(Double(times.count) / (times.last! - times.first!), 1500, "the naive rate")
    let stream = SignalStream(id: "test.gappy", label: "Gappy FID", unit: "V", nominalRate: 8000, provenance: .model, group: StreamGroup.patch)
    stream.ring.append(contentsOf: values, times: times)
    let track = ScopeTrack(stream: stream, coupling: .dc, invert: false, gravity: nil)
    track.ingest()
    XCTAssertEqual(try XCTUnwrap(track.rate), 8000, accuracy: 1e-6)
    // With the right spacing the FFT finds the true pitch inside one block.
    let block = Array(values.suffix(800))
    XCTAssertEqual(try XCTUnwrap(ScopeEngine.fftPeakFrequency(values: block, sampleRate: try XCTUnwrap(track.rate))), 2128.8, accuracy: 2128.8 * 0.005)
    XCTAssertNil(ScopeTrack.medianRate([0, 1, 2]))
  }

  func testASlowStreamBesideAFastOneIsScaledToItsRecentReadings() throws {
    // 10 Hz illuminance around 320 lux: no sample falls inside a 50 ms sweep.
    let stream = SignalStream(id: "test.lux", label: "Illuminance", unit: "lux", nominalRate: 10, provenance: .sim, group: StreamGroup.patch)
    let values: [Float] = [318, 322, 319, 321, 320, 323, 317, 320, 321, 319]
    stream.ring.append(contentsOf: values, times: (0..<10).map { Double($0) / 10 })
    let track = ScopeTrack(stream: stream, coupling: .dc, invert: false, gravity: nil)
    track.ingest()
    let fit = track.fitSamples(0.92...0.97)
    XCTAssertEqual(fit.values.count, 8, "too few in the sweep: its newest eight readings")
    let scale = ScopeEngine.autoScale(
      minimum: Double(try XCTUnwrap(fit.values.min())), maximum: Double(try XCTUnwrap(fit.values.max())), unit: "lux",
      divisions: 1.6)
    XCTAssertEqual(scale.reference, 320, accuracy: 0.5)
    XCTAssertEqual(track.fitSamples(0...0.95).values.count, 10, "a window with samples fits those (plus one either side)")
    // Values in a unit with a note use the base unit's prefixes and keep the note.
    let tiny = ScopeFormat.value(-5.42e-6, unit: "V (norm.)")
    XCTAssertTrue(tiny.hasSuffix("V (norm.)") && tiny.contains("5.42") && !tiny.contains("0.000"), tiny)
  }

  func testCachedPeakAnalyzersAgreeWithFreshOnes() throws {
    let rate = 1000.0
    var cache = ScopeEngine.PeakAnalyzers()
    for f in [47.3, 123.4] {
      let s = sampled(rate: rate, duration: 2) { sin(2 * .pi * f * $0) }
      let fresh = ScopeEngine.measure(values: s.values, times: s.times, sampleRate: rate)
      let cached = ScopeEngine.measure(values: s.values, times: s.times, sampleRate: rate, analyzers: &cache)
      XCTAssertEqual(fresh, cached)
      XCTAssertEqual(try XCTUnwrap(cached.frequencyFFT), f, accuracy: f * 0.005)
    }
  }

  // MARK: - Fourth review pass

  func testAStoppedScopeKeepsItsFrozenSamplesWhenItsStreamRestarts() throws {
    let app = makeApp()
    func tone() -> SignalStream {
      SignalStream(
        id: "test.restart", label: "Restart tone", unit: "µT", nominalRate: 200, provenance: .sim, group: StreamGroup.patch,
        capacity: 2000)
    }
    let first = tone()
    app.streams.register(first)
    let now = SignalClock.now()
    let s = sampled(rate: 200, duration: 2, start: now - 2) { sin(2 * .pi * 5 * $0) }
    first.ring.append(contentsOf: s.values, times: s.times)
    let model = ScopeModel(owner: "scope.test.restart", persistent: false, fixedStreams: ["test.restart"])
    model.appear(app: app)
    model.setTimebase(0.1)
    model.tick()
    model.toggleRun()
    let frozen = model.displayWindow
    let before = try XCTUnwrap(model.samples(0, in: frozen)).values.count
    XCTAssertGreaterThan(before, 150)
    // Off screen and back while stopped; meanwhile the source restarted with a fresh stream
    // instance under the same id (Live sources and the probe streams make one per run).
    model.disappear()
    app.streams.unregister(first)
    let second = tone()
    app.streams.register(second)
    second.ring.append(contentsOf: [0.5], times: [SignalClock.now()])
    model.appear(app: app)
    defer { model.disappear() }
    Thread.sleep(forTimeInterval: 0.01)
    model.tick()
    XCTAssertEqual(model.displayWindow, frozen, "still frozen")
    XCTAssertEqual(try XCTUnwrap(model.samples(0, in: frozen)).values.count, before, "the frozen samples stay")
    // Run takes the new stream.
    model.toggleRun()
    Thread.sleep(forTimeInterval: 0.01)
    model.tick()
    XCTAssertTrue(model.track(for: 0)?.stream === second)
  }

  func testSwitchingTheAnalyzedChannelToASlowStreamLengthensTheWindowAgain() throws {
    let app = makeApp()
    let now = SignalClock.now()
    let fast = SignalStream(
      id: "test.fast", label: "Fast flicker", unit: "rel.", nominalRate: 2000, provenance: .sim, group: StreamGroup.patch,
      capacity: 2000 * 12)
    let slow = SignalStream(
      id: "test.slow", label: "Slow lux", unit: "lux", nominalRate: 10, provenance: .sim, group: StreamGroup.patch, capacity: 1200)
    let f = sampled(rate: 2000, duration: 10, start: now - 10) { sin(2 * .pi * 120 * $0) }
    let l = sampled(rate: 10, duration: 120, start: now - 120) { 320 + 3 * sin(2 * .pi * 0.7 * $0) }
    fast.ring.append(contentsOf: f.values, times: f.times)
    slow.ring.append(contentsOf: l.values, times: l.times)
    app.streams.register([fast, slow])
    let model = ScopeModel(owner: "scope.test.analysis", persistent: false, fixedStreams: ["test.fast", "test.slow"])
    model.appear(app: app)
    defer { model.disappear() }
    model.setTimebase(0.005)
    model.setMode(.fft)
    model.tick()
    XCTAssertGreaterThanOrEqual(model.timebase * 10, 1024 / 2000.0, "1024 samples of the 2 kHz channel")
    XCTAssertNotNil(model.spectrum)
    // The 10 Hz channel needs a far longer window: without a second check it would read
    // "Collecting samples…" for good.
    model.mutate { $0.analysisChannel = 1 }
    Thread.sleep(forTimeInterval: 0.01)
    model.tick()
    XCTAssertEqual(model.timebase, 10, accuracy: 1e-9, "the longest window the streams allow (100 s)")
    let spectrum = try XCTUnwrap(model.spectrum)
    XCTAssertEqual(spectrum.sampleRate, 10, accuracy: 0.01)
  }

  func testNormalDrawsAndMeasuresNothingUntilItsFirstEdge() throws {
    let app = makeApp()
    let stream = SignalStream(
      id: "test.normal", label: "Normal tone", unit: "µT", nominalRate: 1000, provenance: .sim, group: StreamGroup.patch,
      capacity: 4000)
    app.streams.register(stream)
    let now = SignalClock.now()
    let s = sampled(rate: 1000, duration: 2, start: now - 2) { sin(2 * .pi * 25 * $0) }
    stream.ring.append(contentsOf: s.values, times: s.times)
    let model = ScopeModel(owner: "scope.test.normal", persistent: false, fixedStreams: ["test.normal"])
    model.appear(app: app)
    defer { model.disappear() }
    model.setTimebase(0.01)
    model.mutate { s in
      s.channels[0].autoScale = false
      s.trigger.mode = .normal
      s.trigger.level = 5
    }
    func frameSegments() -> Int {
      var frame = ScopeFrame()
      let size = CGSize(width: 400, height: 320)
      frame.reset(size: size, reduceMotion: false)
      model.buildScopeFrame(&frame, size: size, dt: 1.0 / 60)
      return frame.overlay.phosphor.count
    }
    // The level lies above the ±1 µT tone: no edge, so no trace, no measurements, no CSV.
    Thread.sleep(forTimeInterval: 0.25)
    let waiting = frameSegments()
    XCTAssertEqual(model.readout.status, .waiting)
    XCTAssertTrue(model.readout.measurements.isEmpty)
    XCTAssertTrue(model.export.isEmpty)
    XCTAssertLessThan(waiting, 12, "ground and trigger markers only, never a free-running trace")
    // The level on the tone: the next edge triggers a sweep, which is drawn and measured.
    model.mutate { $0.trigger.level = 0 }
    Thread.sleep(forTimeInterval: 0.25)
    let triggered = frameSegments()
    XCTAssertEqual(model.readout.status, .triggered)
    XCTAssertGreaterThan(triggered, 50)
    XCTAssertEqual(try XCTUnwrap(model.readout.measurements[0]?.frequencyZeroCrossing), 25, accuracy: 0.2)
  }

  func testAutoFitsTheMathTraceToo() throws {
    let app = makeApp()
    let now = SignalClock.now()
    let a = SignalStream(id: "test.ma", label: "A", unit: "µT", nominalRate: 100, provenance: .sim, group: StreamGroup.patch)
    let b = SignalStream(id: "test.mb", label: "B", unit: "µT", nominalRate: 100, provenance: .sim, group: StreamGroup.patch)
    let sa = sampled(rate: 100, duration: 4, start: now - 4) { 30 + sin(2 * .pi * 2 * $0) }
    let sb = sampled(rate: 100, duration: 4, start: now - 4) { 20 + 0.5 * sin(2 * .pi * 3 * $0) }
    a.ring.append(contentsOf: sa.values, times: sa.times)
    b.ring.append(contentsOf: sb.values, times: sb.times)
    app.streams.register([a, b])
    let model = ScopeModel(owner: "scope.test.automath", persistent: false, fixedStreams: ["test.ma", "test.mb"])
    model.appear(app: app)
    defer { model.disappear() }
    model.setTimebase(0.2)
    model.mutate { s in
      s.math.enabled = true
      s.math.operation = .sum
      s.math.a = .channel(0)
      s.math.b = .channel(1)
      s.math.autoScale = false
      s.math.unitsPerDiv = 500
      s.math.reference = 0
    }
    model.tick()
    model.autoset()
    let m = model.settings.math
    XCTAssertTrue(m.autoScale)
    XCTAssertEqual(m.reference, 50, accuracy: 1.5, "A + B is centered on its 50 µT mean")
    XCTAssertLessThanOrEqual(m.unitsPerDiv, 1, "≈ 3 µT of swing over six divisions")
  }
}

/// A small deterministic generator for jittered timestamps (SplitMix64).
private struct ScopeTestRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

  mutating func uniform() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(1 << 53)
  }
}
