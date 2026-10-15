import Foundation

/// Display mappings of the spectra-lab instruments that the native Spectrum tab reuses
/// (port-plan §9.2; spectra-lab `ui/app.js`, `ui/feedback.js`, `instruments/*.js`).
/// UI-framework-free: geometry constants, time windows, JS-exact readout strings and the
/// sound-pitch map. Colours are spectra-lab THEME hex strings; the app maps them to its tokens.
nonisolated enum SpectrumDisplay {
  // MARK: Instrument controls (ui/controls.js, instruments/*.js)

  /// κ display-speed slider: log₁₀ κ over [−1.3, 0.6] (0.05…3.98 reference cycles per screen
  /// second), step 0.01 (`controls.js`).
  static let speedLogRange: ClosedRange<Double> = -1.3...0.6
  /// Decompose polarizer slider α, degrees, step 1 (`decompose.js`).
  static let polarizerRange: ClosedRange<Double> = 0...180
  /// Decompose probe-strength slider: log₁₀ a₀ over [−2, 1], step 0.01 (`decompose.js`).
  static let a0LogRange: ClosedRange<Double> = -2...1
  /// Matter-bench oscillator resonance slider: log₁₀ λ₀ (m) over [−8, 0], step 0.01 (`bench.js`).
  static let lambda0LogRange: ClosedRange<Double> = -8...0

  // MARK: Wave scope (instruments/scope.js)

  /// Beam axis drawn, in reference wavelengths.
  static let scopeZRange: ClosedRange<Double> = -1.6...1.6
  /// Scene amplitude of a unit field.
  static let scopeAmplitude: Double = 0.62
  /// Samples along the beam.
  static let scopeSamples = 260
  /// Camera pitch clamp, degrees.
  static let scopePitchRange: ClosedRange<Double> = -60...80
  /// Zoom clamp.
  static let scopeZoomRange: ClosedRange<Double> = 0.4...4
  /// Drag sensitivity, degrees of yaw per point.
  static let scopeYawPerPoint: Double = 0.4
  /// Drag sensitivity, degrees of pitch per point.
  static let scopePitchPerPoint: Double = 0.3

  // MARK: Decompose · polarization

  /// The tip trail covers one reference period in this many steps.
  static let polarizationTrailSamples = 120

  /// Screen time of trail sample `i`: t − i/(120·κ).
  static func polarizationTrailTime(_ i: Int, t: Double, speed: Double) -> Double {
    t - Double(i) / (Double(polarizationTrailSamples) * speed)
  }

  /// Time span of the Ex(t)/Ey(t) strips, 2.2/κ s (newest sample on the right).
  static func componentStripSpan(speed: Double) -> Double { 2.2 / speed }

  /// Field component along a polarizer at `alphaDeg`: p = ex·cos α + ey·sin α.
  static func polarizerProjection(ex: Double, ey: Double, alphaDeg: Double) -> Double {
    let a = Wave.rad(alphaDeg)
    return ex * cos(a) + ey * sin(a)
  }

  /// The ellipse's major-axis angle as the readout prints it, "30°", or "—" for circular
  /// light, whose orientation is numerical noise (the web prototype printed it, e.g. "8°";
  /// port-plan §7 Q13).
  static func orientationText(_ e: Wave.Ellipse) -> String {
    e.kind == .circular ? "\u{2014}" : JSFormat.jsString(JSMath.round(e.orientation)) + "\u{00B0}"
  }

  /// Decompose › Polarization readouts for the active source: Ex₀, Ey₀, δ lag, polarizer pass
  /// fraction, ellipse orientation and sense.
  static func polarizationReadouts(_ state: SpectraState) -> [Readout] {
    let src = state.activeSource, e = Wave.ellipse(src), alpha = state.decompose.polarizer
    let psi = Wave.rad(src.theta)
    let passes = JSMath.round(Wave.polarizerTransmission(src, alphaDeg: alpha) * 100)
    return [
      Readout(key: "Ex\u{2080}", value: JSFormat.toFixed(abs(cos(psi)), 2), sub: "of E\u{2080}", colorHex: "#1aedff"),
      Readout(key: "Ey\u{2080}", value: JSFormat.toFixed(abs(sin(psi)), 2), sub: "of E\u{2080}", colorHex: "#ffe82e"),
      Readout(
        key: "\u{03B4} lag", value: JSFormat.jsString(JSMath.round(src.delta)) + "\u{00B0}", sub: e.kind.rawValue,
        colorHex: "#ff8fb8"),
      Readout(
        key: "Passes", value: JSFormat.jsString(passes) + "%", sub: "polarizer at " + JSFormat.jsString(alpha) + "\u{00B0}",
        colorHex: "#ffbf5e"),
      Readout(key: "Ellipse", value: orientationText(e), sub: e.sense?.rawValue ?? "no rotation", colorHex: "#e8f1ec"),
    ]
  }

  /// The caption under the polarization view.
  static func polarizationNote(_ state: SpectraState) -> String {
    let src = state.activeSource, e = Wave.ellipse(src)
    switch e.kind {
    case .linear:
      let passes = JSMath.round(Wave.polarizerTransmission(src, alphaDeg: state.decompose.polarizer) * 100)
      return "Ex and Ey move in step, so the tip of E slides along a line at \(orientationText(e)). Malus's law: "
        + "\(JSFormat.jsString(passes))% gets through."
    case .circular:
      return "Ey trails Ex by a quarter cycle, so the tip of E traces a circle. Every polarizer angle passes exactly half."
    case .elliptical:
      return "Ey trails Ex by \(JSFormat.jsString(JSMath.round(src.delta)))\u{00B0}, so the tip of E traces an ellipse. "
        + "How much passes depends on how the polarizer lines up with it."
    }
  }

  // MARK: Decompose · probe charge

  /// Decompose › Probe charge readouts: the a₀ shown and its drift, the E₀ it needs at the
  /// active λ, the active source's own a₀, and its quiver amplitude.
  static func probeReadouts(_ state: SpectraState) -> [Readout] {
    let src = state.activeSource, a = state.decompose.a0
    let real = Wave.a0(e0: src.e0, lambda: src.lambda)
    return [
      Readout(
        key: "a\u{2080} shown", value: JSFormat.toPrecision(a, 3),
        sub: "drift " + JSFormat.toPrecision(Wave.driftSpeed(a) * 100, 3) + "% of c", colorHex: "#ffbf5e"),
      Readout(
        key: "E\u{2080} needed", value: JSFormat.sci(Wave.fieldForA0(a, lambda: src.lambda), unit: "V/m"),
        sub: "at " + Spectrum.describe(src.lambda).text.lambda, colorHex: "#61b3ff"),
      Readout(
        key: "Your source", value: "a\u{2080} " + JSFormat.sci(real), sub: "E\u{2080} " + JSFormat.sci(src.e0, unit: "V/m"),
        colorHex: "#e8f1ec"),
      Readout(
        key: "Quiver", value: Spectrum.describe(Wave.quiverAmplitude(e0: src.e0, lambda: src.lambda)).text.lambda,
        sub: "your electron's swing", colorHex: "#59f0b0"),
    ]
  }

  /// The caption under the probe view for the current force mode.
  static func probeNote(_ state: SpectraState) -> String {
    switch state.decompose.probeMode {
    case .both:
      state.decompose.a0 < 0.3
        ? "E shakes the electron sideways. The v\u{00D7}B push is a\u{2080}\u{00B2}/4 as big, too small to see here. Raise a\u{2080} to watch it."
        : "E shakes the electron sideways; v\u{00D7}B then pushes it forward twice per cycle. Riding along with the drift, it traces a figure eight."
    case .electric:
      "With the magnetic force switched off, the electron only shakes back and forth and never moves along the beam."
    case .magnetic:
      "B alone does nothing: v\u{00D7}B needs a moving charge, and this one starts at rest. E has to get it moving first."
    }
  }

  /// "Drift 50% c" tag, or "No drift" unless both forces act.
  static func driftTag(_ state: SpectraState) -> String {
    state.decompose.probeMode == .both
      ? "Drift " + JSFormat.toPrecision(Wave.driftSpeed(state.decompose.a0) * 100, 2) + "% c" : "No drift"
  }

  /// Carrier cycles of the cached probe trajectory.
  static let probeCycles: Double = 3
  /// Integration steps of the cached probe trajectory.
  static let probeSteps = 900

  /// The probe's trajectory, `electronTrajectory(src, a0, mode, 3, 900)`. Cache it by
  /// (a₀, mode, θ, δ): nothing else changes it.
  static func probeTrajectory(_ s: WaveSource, a0: Double, mode: Wave.ProbeMode) -> [Wave.TrajectoryPoint] {
    Wave.electronTrajectory(s, a: a0, mode: mode, cycles: probeCycles, steps: probeSteps)
  }

  /// Transverse position projected on the polarization direction, x·cos ψ + y·sin ψ.
  static func transverse(_ p: Wave.TrajectoryPoint, thetaDeg: Double) -> Double {
    let psi = Wave.rad(thetaDeg)
    return p.x * cos(psi) + p.y * sin(psi)
  }

  /// Index of the animated electron: η = (2π·κ·t·0.5) mod (2π·3), mapped onto the samples.
  static func probeIndex(t: Double, speed: Double, count: Int) -> Int {
    guard count > 1 else { return 0 }
    let span = Wave.tau * probeCycles
    let eta = (Wave.tau * speed * t * 0.5).truncatingRemainder(dividingBy: span)
    let i = JSMath.round((eta / span) * Double(count - 1))
    guard i.isFinite else { return 0 }
    return Swift.max(0, Swift.min(count - 1, Int(i)))
  }

  /// The figure eight seen riding with the drift: (z − v_d·t, transverse) with
  /// v_d = z_end/t_end. Empty when the trajectory is empty.
  static func driftFrame(_ trajectory: [Wave.TrajectoryPoint], thetaDeg: Double) -> [SIMD2<Double>] {
    guard let end = trajectory.last else { return [] }
    let vd = end.z / end.t
    return trajectory.map { SIMD2($0.z - vd * $0.t, transverse($0, thetaDeg: thetaDeg)) }
  }

  // MARK: Decompose · Fourier

  /// Components per source on the stem plot.
  static let fourierStemCount = 41

  /// Time window of the summed trace, 4/κ s.
  static func fourierWindow(speed: Double) -> Double { 4 / speed }

  /// The summed trace value (ex + ey)·0.707.
  static func fourierTrace(_ p: FieldView.FieldPoint) -> Double { (p.ex + p.ey) * 0.707 }

  /// log₁₀ f axis of the stems: [min − 0.15, max + 0.15], widened to at least 0.4 decades
  /// about its centre. Nil for no stems.
  static func stemAxis(logFrequencies: [Double]) -> ClosedRange<Double>? {
    guard let lo0 = logFrequencies.min(), let hi0 = logFrequencies.max() else { return nil }
    var lo = lo0 - 0.15, hi = hi0 + 0.15
    if hi - lo < 0.4 {
      let m = (hi + lo) / 2
      lo = m - 0.2
      hi = m + 0.2
    }
    return lo...hi
  }

  /// Minimum deviation through a 60° prism of index n, radians: 2·asin(min(1, n·sin 30°)) − 60°.
  static func prismDeviation(n: Double) -> Double {
    2 * asin(JSMath.min(1, n * sin(Double.pi / 6))) - Double.pi / 3
  }

  /// The prism inset exaggerates the spread between colours by this factor.
  static let prismSpreadExaggeration: Double = 8

  // MARK: Spectrum tuner

  /// "One wave ≈ 5.5× a virus" / "One wave ≈ 1/3.2 of a cell" (tuner status line).
  static func comparisonPhrase(_ lambda: Double) -> String {
    let c = Spectrum.nearestComparison(lambda)
    let r =
      c.ratio >= 1
      ? JSFormat.toFixed(c.ratio, c.ratio < 10 ? 1 : 0) + "\u{00D7}"
      : "1/" + JSFormat.toFixed(1 / c.ratio, 1 / c.ratio < 10 ? 1 : 0) + " of"
    return "One wave \u{2248} \(r) \(c.label)"
  }

  /// Ruler tick label for the decade 10^e m ("1 nm", "100 µm", "1 cm", "10 cm", "100 km").
  /// Beyond the web range it keeps counting kilometres ("100000 km" at e = 8), as the JS would.
  static func decadeLabel(_ e: Int) -> String {
    if e == -2 { return "1 cm" }
    if e == -1 { return "10 cm" }
    let units: [(base: Int, unit: String)] = [(-12, "pm"), (-9, "nm"), (-6, "\u{00B5}m"), (-3, "mm"), (0, "m"), (3, "km")]
    let u = units.last { $0.base <= e } ?? (-15, "fm")
    return JSFormat.jsString(pow(10, Double(e - u.base))) + " " + u.unit
  }

  /// Temperature of a thermal source dragged to log₁₀ λ = `lg`: Wien b/λ, clamped to [1, 1e8] K.
  static func thermalTemperature(atLog lg: Double) -> Double {
    JSMath.min(1e8, JSMath.max(1, SI.wienB / pow(10, lg)))
  }

  // MARK: Spectroscopy lab

  /// Automatic sweep speed, axis fraction per second (a full scan takes ~17 s).
  static let labSweepRate: Double = 0.06

  /// Cursor/axis text: "2349 cm⁻¹", "1.22 ppm", or the wavelength readout.
  static func labAxisText(_ sample: SampleKey, x: Double) -> String {
    switch sample.axis.kind {
    case .wavenumber: JSFormat.sig3(x) + " cm\u{207B}\u{00B9}"
    case .ppm: JSFormat.toFixed(x, 2) + " ppm"
    case .lambda, .lambdaLog: Spectrum.describe(x).text.lambda
    }
  }

  /// Plot normalization: the largest value over 2,401 axis points (at least 1e-12).
  static func labMaximum(_ sample: SampleKey, mode: SampleMode) -> Double {
    var m = 1e-12
    for i in 0...2400 { m = JSMath.max(m, sample.value(sample.axis.x(at: Double(i) / 2400), mode: mode)) }
    return m
  }

  // MARK: Readouts (ui/app.js)

  /// One readout row: label, value, subtitle and the spectra-lab accent colour.
  struct Readout: Hashable, Sendable {
    var key: String
    var value: String
    var sub: String
    var colorHex: String
  }

  /// Real index the readouts use: 1 in vacuum, else the medium's n even where `valid` is false
  /// (unlike `FieldView`, which draws an invalid index as n = 1).
  static func readoutIndex(_ medium: Matter.Medium, lambda: Double) -> Double {
    medium == .vacuum ? 1 : medium.index(lambda).n
  }

  /// The default readout grid for the active source: λ, f, E, B₀, intensity, plus n in a medium.
  static func readouts(_ state: SpectraState) -> [Readout] {
    let src = state.activeSource
    let d = Spectrum.describe(src.lambda)
    let m = state.medium.index(src.lambda)
    let n = state.medium == .vacuum ? 1 : m.n
    let inMedium = state.medium != .vacuum
    var rows = [
      Readout(
        key: "\u{03BB} wavelength", value: d.text.lambda,
        sub: inMedium && m.valid
          ? Spectrum.describe(src.lambda / n).text.lambda + " in " + state.medium.name.lowercased()
          : d.text.wavenumber,
        colorHex: d.colorHex),
      Readout(key: "f frequency", value: d.text.f, sub: "period " + JSFormat.sci(1 / d.f, unit: "s"), colorHex: "#59f0b0"),
      Readout(key: "E photon", value: d.text.ev, sub: d.text.kcal, colorHex: "#ffbf5e"),
      Readout(
        key: "B\u{2080} field", value: JSFormat.sci(Wave.peakB(e0: src.e0, n: n), unit: "T"),
        sub: "E\u{2080} " + JSFormat.sci(src.e0, unit: "V/m"), colorHex: "#ff5c7a"),
      Readout(
        key: "Intensity", value: JSFormat.sci(Wave.intensity(e0: src.e0, n: n), unit: "W/m\u{00B2}"),
        sub: JSFormat.sci(Wave.photonFlux(e0: src.e0, lambda: src.lambda, n: n) * 1e-4) + " photons/cm\u{00B2}\u{00B7}s",
        colorHex: "#e8f1ec"),
    ]
    if inMedium {
      rows.append(
        Readout(
          key: "n medium", value: m.valid ? JSFormat.toFixed(m.n, 4) : "no data",
          sub: m.valid ? "speed " + JSFormat.toFixed(1 / m.n, 3) + " c" : "outside model range", colorHex: "#ffbf5e"))
    }
    return rows
  }

  /// Default status line: the sub-band on the left, the ionization class in capitals on the right.
  /// Beyond the web range (λ > 1 km, extended ruler only) the left side names the ITU band
  /// (`Spectrum.rulerSubBand`: "ULF", "ELF", …) instead of the JS fallback "Radio".
  static func statusLine(_ state: SpectraState) -> (left: String, right: String) {
    let lambda = state.activeSource.lambda
    let d = Spectrum.describe(lambda)
    let sub = lambda > pow(10, Spectrum.logMax) ? Spectrum.rulerSubBand(at: lambda) : d.sub
    return (sub, d.ion.label.uppercased())
  }

  /// Transport text "6.62×10¹⁴× slower". Only the native extended ruler can put the reference
  /// below κ cycles/s (f < 4 Hz, λ > 75,000 km): the display then runs faster than reality and
  /// reads "1.33×10⁰× faster" instead of a "slower" factor below 1. The web range never gets
  /// there (f ≥ 300 kHz), so parity is unchanged.
  static func slowMotionText(_ state: SpectraState) -> String {
    let s = state.slowMotion
    if s > 0 && s < 1 { return JSFormat.sci(1 / s) + "\u{00D7} faster" }
    return JSFormat.sci(s) + "\u{00D7} slower"
  }

  // MARK: Feedback (ui/feedback.js)

  /// Hum pitch for a source frequency: 15 decades (3e5…3e21 Hz) map onto four octaves above
  /// 110 Hz, 110·2^(4·(log₁₀ f − 5.5)/16).
  static func soundPitch(frequency f: Double) -> Double { 110 * pow(2, (4 * (log10(f) - 5.5)) / (21.5 - 5.5)) }

  /// Minimum spacing of haptic transients, s.
  static let hapticMinInterval: Double = 0.035
  /// Minimum spacing of detent ticks, s.
  static let tickMinInterval: Double = 0.045
}

nonisolated extension SampleMode {
  /// Lab toolbar name (spectra-lab `MODE_NAMES`).
  var name: String {
    switch self {
    case .emission: "Emission"
    case .absorption: "Absorption"
    case .ir: "IR absorption"
    case .raman: "Raman"
    case .a: "Chlorophyll a"
    case .b: "Chlorophyll b"
    case .nmr400: "400 MHz"
    case .nmr60: "60 MHz"
    }
  }
}

nonisolated extension Samples {
  /// Conventional name of a hydrogen line (Lyα, Hα…Hδ, Paα), or nil.
  static func lineName(n1: Int, n2: Int) -> String? {
    switch (n1, n2) {
    case (1, 2): "Ly\u{03B1}"
    case (2, 3): "H\u{03B1}"
    case (2, 4): "H\u{03B2}"
    case (2, 5): "H\u{03B3}"
    case (2, 6): "H\u{03B4}"
    case (3, 4): "Pa\u{03B1}"
    default: nil
    }
  }
}
