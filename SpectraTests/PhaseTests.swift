// Phase-space engine oracles: Utkarsh's convention (C) and spacetime Wigner Φ(ν,k;x,t)
// (Docs/research/wigner-spacetime.md), checked on the discrete implementation: exact marginals
// M1/M2/P, reality, Hudson positivity, cross terms, chirp concentration, plane-wave signs, the
// Moyal identity, Fresnel shear, aperture far field vs the RF array factor, closed-form Gaussian
// packets, dispersion shells and the live timing budgets.
//
// One source for two runners: XCTest (`PhaseTests` below, in the app's test target) and the
// macOS harness (Tools/check-phase.sh compiles this file with Spectra/Phase, Spectra/Core and
// Spectra/RF plus Tools/harness/phase/main.swift, -D SPECTRA_HARNESS).
import Foundation
import simd

#if !SPECTRA_HARNESS
  import XCTest

  @testable import Spectra
#endif

/// One oracle comparison.
nonisolated struct PhaseCheck: Sendable, Hashable {
  let name: String
  let passed: Bool
  let detail: String
}

/// Collects the comparisons of one group.
nonisolated struct PhaseCheckLog: Sendable {
  private(set) var checks: [PhaseCheck] = []

  mutating func check(_ name: String, _ ok: Bool, _ detail: String) {
    checks.append(PhaseCheck(name: name, passed: ok, detail: detail))
  }
}

/// The oracle suite, grouped as the XCTest methods are.
nonisolated enum PhaseOracleSuite {
  struct Group: Sendable {
    let name: String
    let run: @Sendable () -> [PhaseCheck]
  }

  static let groups: [Group] = [
    Group(name: "Conventions and plane-wave signs", run: conventions),
    Group(name: "Analytic signal and oversampling", run: analyticSignal),
    Group(name: "Temporal Wigner marginals", run: temporalMarginals),
    Group(name: "Spatial Wigner marginals", run: spatialMarginals),
    Group(name: "Hudson positivity and cross terms", run: hudsonAndCrossTerms),
    Group(name: "Linear chirp concentration", run: chirpConcentration),
    Group(name: "Moyal identity", run: moyal),
    Group(name: "Pseudo, smoothed and spectrogram", run: pseudoSmoothedSpectrogram),
    Group(name: "Aperture far field and Fresnel shear", run: apertureAndFresnel),
    Group(name: "Spacetime Wigner Φ", run: spacetime),
    Group(name: "Packets, closed forms and dispersion shells", run: packetsAndDispersion),
    Group(name: "Timing budgets", run: timing),
    Group(name: "Robustness at the edges", run: robustness),
    Group(name: "Independent references (direct sums, closed forms)", run: independentReferences),
  ]

  // MARK: Helpers

  static func rel(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(abs(b), 1e-300) }
  static func fmt(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)g", x) }

  /// max |a − b| / scale.
  static func maxDiff(_ a: [Double], _ b: [Double], scale: Double) -> Double {
    precondition(a.count == b.count, "maxDiff: lengths differ")
    var m = 0.0
    for i in 0..<a.count { m = max(m, abs(a[i] - b[i])) }
    return m / max(scale, 1e-300)
  }

  /// A Gaussian packet record in convention (C): time e^{−2πi(ν₀u + ½αu²)}, space e^{+i(k₀u + βu²)},
  /// envelope e^{−u²/(4σ²)}, u = coordinate − centre.
  static func packet(
    count n: Int, step: Double, center: Double, sigma: Double, carrier: Double, chirp: Double = 0,
    domain: Phase.Domain = .time, amplitude: Double = 1
  ) -> Phase.Signal {
    Phase.Signal(count: n, step: step, origin: 0, domain: domain) { x in
      let u = x - center
      let env = amplitude * exp(-u * u / (4 * sigma * sigma))
      let ph: Double =
        domain == .time ? -2 * Double.pi * (carrier * u + 0.5 * chirp * u * u) : carrier * u + chirp * u * u
      return SIMD2(env * cos(ph), env * sin(ph))
    }
  }

  /// Frequency of the dominant oscillation of y (cycles per unit of `step`), searched in
  /// [f0 − span, f0 + span] by a Hann-weighted DTFT scan with parabolic refinement.
  static func dominantFrequency(_ y: [Double], step: Double, around f0: Double, span: Double) -> Double {
    let n = y.count
    let w = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(n)) }
    let mean = zip(y, w).map(*).reduce(0, +) / w.reduce(0, +)
    func power(_ f: Double) -> Double {
      var sr = 0.0
      var si = 0.0
      for i in 0..<n {
        let v = (y[i] - mean) * w[i]
        let ph = -2 * Double.pi * f * Double(i) * step
        sr += v * cos(ph)
        si += v * sin(ph)
      }
      return sr * sr + si * si
    }
    let steps = 2000
    var best = f0
    var bestP = -1.0
    let df = 2 * span / Double(steps)
    for i in 0...steps {
      let f = f0 - span + Double(i) * df
      let p = power(f)
      if p > bestP {
        bestP = p
        best = f
      }
    }
    let pm = power(best - df)
    let pp = power(best + df)
    let den = pm - 2 * bestP + pp
    return den != 0 ? best + 0.5 * df * (pm - pp) / den : best
  }

  // MARK: - Conventions and plane-wave signs

  static func conventions() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // DFT against a direct sum (vDSP 48 and the O(N²) fallback at 12), both signs.
    for n in [48, 12] {
      let dft = Phase.DFT(count: n)
      let re = (0..<n).map { sin(0.7 * Double($0) + 0.3) + 0.1 * Double($0 % 5) }
      let im = (0..<n).map { cos(1.3 * Double($0)) - 0.2 }
      var worst = 0.0
      for (sign, s) in [(Phase.DFT.Sign.negative, -1.0), (.positive, 1.0)] {
        let (fr, fi) = dft.transform(sign, re: re, im: im)
        for q in 0..<n {
          var ar = 0.0
          var ai = 0.0
          for j in 0..<n {
            let ph = s * 2 * Double.pi * Double(q * j) / Double(n)
            ar += re[j] * cos(ph) - im[j] * sin(ph)
            ai += re[j] * sin(ph) + im[j] * cos(ph)
          }
          worst = max(worst, abs(fr[q] - ar), abs(fi[q] - ai))
        }
      }
      log.check(
        "DFT N = \(n) (\(dft.isAccelerated ? "vDSP" : "table fallback")) vs direct sum", worst < 1e-11,
        "max |Δ| \(fmt(worst))")
    }
    log.check(
      "vDSP sizes", Phase.DFT.goodSize(atLeast: 48) == 48 && Phase.DFT.goodSize(atLeast: 49) == 64
        && Phase.DFT.isFast(48) && !Phase.DFT.isFast(12) && Phase.DFT.goodSize(atLeast: 100) == 120,
      "goodSize(49) = \(Phase.DFT.goodSize(atLeast: 49)), goodSize(100) = \(Phase.DFT.goodSize(atLeast: 100))")

    // Time: e^{−2πiν₀t} lands at +ν₀ (fs = 1 kHz, ν₀ = 125 Hz).
    let fs = 1000.0
    let z = packet(count: 256, step: 1 / fs, center: 0.128, sigma: 0.02, carrier: 125)
    let w = Phase.wigner(z)
    let wm = w.columnMarginal()
    let nuPeak = w.columnAxis.value(wm.indices.max { wm[$0] < wm[$1] }!)
    let spec = Phase.spectrum(z, bins: w.columns, band: .positive)
    let specPeak = spec.axis.value(spec.power.indices.max { spec.power[$0] < spec.power[$1] }!)
    log.check(
      "time: e^{−2πiν₀t} lands at +ν₀ (Wigner and |Z|²)", abs(nuPeak - 125) <= w.columnAxis.step && abs(specPeak - 125) <= spec.axis.step,
      "Wigner peak \(fmt(nuPeak, 5)) Hz, |Z|² peak \(fmt(specPeak, 5)) Hz, bin \(fmt(w.columnAxis.step, 4)) Hz")

    // Real cos → analytic → +ν₀; engineering I + jQ e^{+j2πft} → +f.
    let real = (0..<256).map { cos(2 * Double.pi * 125 * Double($0) / fs) * exp(-pow((Double($0) - 128) / 40, 2)) }
    let wv = Phase.wignerVille(real: real, step: 1 / fs)
    let m2 = wv.columnMarginal()
    let wvPeak = wv.columnAxis.value(m2.indices.max { m2[$0] < m2[$1] }!)
    let iq: [SIMD2<Double>] = (0..<256).map {
      let t = Double($0) / fs
      let e = exp(-pow((Double($0) - 128) / 40, 2))
      return SIMD2(e * cos(2 * Double.pi * 100 * t), e * sin(2 * Double.pi * 100 * t))
    }
    let wiq = Phase.wigner(Phase.Signal.fromIQ(iq, sampleRate: fs), options: Phase.WignerOptions(band: .centered))
    let m2iq = wiq.columnMarginal()
    let iqPeak = wiq.columnAxis.value(m2iq.indices.max { m2iq[$0] < m2iq[$1] }!)
    log.check(
      "real cos via analytic signal → +ν₀; I + jQ e^{+j2πft} via fromIQ → +f",
      abs(wvPeak - 125) <= wv.columnAxis.step && abs(iqPeak - 100) <= wiq.columnAxis.step,
      "cos 125 Hz → \(fmt(wvPeak, 5)) Hz; IQ +100 Hz → \(fmt(iqPeak, 5)) Hz")

    // Space: e^{+ik₀x} lands at +k₀ (Δx = 0.1 m, k₀ = 5 rad/m, centred band ±π/(2Δx)).
    let psi = packet(count: 256, step: 0.1, center: 12.8, sigma: 2, carrier: 5, domain: .space)
    let ws = Phase.wigner(psi)
    let ms = ws.columnMarginal()
    let kPeak = ws.columnAxis.value(ms.indices.max { ms[$0] < ms[$1] }!)
    let mirror = Phase.wigner(psi.conjugated()).columnMarginal()
    let kMirror = ws.columnAxis.value(mirror.indices.max { mirror[$0] < mirror[$1] }!)
    log.check(
      "space: e^{+ik₀x} lands at +k₀, its conjugate at −k₀",
      abs(kPeak - 5) <= ws.columnAxis.step && abs(kMirror + 5) <= ws.columnAxis.step,
      "k peak \(fmt(kPeak, 4)) rad/m, conjugate \(fmt(kMirror, 4)) rad/m (bin \(fmt(ws.columnAxis.step, 3)))")

    // Spacetime: e^{i(k₀x − 2πν₀t)} lands at (+k₀, +ν₀); e^{i(−k₀x − 2πν₀t)} at (−k₀, +ν₀).
    for sx in [1.0, -1.0] {
      let f = gatedPacketField(n: 48, k0: sx * 0.5, nu0: 0.25, velocity: sx * 1, sigmaX: 3, sigmaT: 3)
      let st = Phase.spacetimeWigner(f)
      let g = st.m2Grid.argMax
      let kAt = st.kAxis.value(g.row)
      let nuAt = st.nuAxis.value(g.column)
      log.check(
        "spacetime: packet e^{i(\(sx > 0 ? "+" : "−")k₀x − 2πν₀t)} lands at (\(sx > 0 ? "+" : "−")k₀, +ν₀)",
        abs(kAt - sx * 0.5) <= st.kAxis.step && abs(nuAt - 0.25) <= st.nuAxis.step,
        "M2 peak (k, ν) = (\(fmt(kAt, 4)), \(fmt(nuAt, 4))) vs (\(fmt(sx * 0.5, 3)), 0.25), bins (\(fmt(st.kAxis.step, 3)), \(fmt(st.nuAxis.step, 3)))")
    }
    return log.checks
  }

  /// A 2-D Gaussian packet on an n × n grid with Δx = Δt = 1 (grid units): carrier (k₀, ν₀),
  /// moving at `velocity` samples per sample, rms widths σ_x (in the moving frame) and σ_t.
  static func gatedPacketField(
    n: Int, k0: Double, nu0: Double, velocity v: Double, sigmaX: Double, sigmaT: Double, centerX: Double? = nil,
    centerT: Double? = nil, amplitude: Double = 1
  ) -> Phase.Field {
    let c = Double(n - 1) / 2
    let cx = centerX ?? c
    let ct = centerT ?? c
    return Phase.Field(x: Phase.Axis(start: 0, step: 1, count: n), t: Phase.Axis(start: 0, step: 1, count: n)) { x, t in
      let u = x - cx - v * (t - ct)
      let env = amplitude * exp(-u * u / (4 * sigmaX * sigmaX) - (t - ct) * (t - ct) / (4 * sigmaT * sigmaT))
      let ph = k0 * (x - cx) - 2 * Double.pi * nu0 * (t - ct)
      return SIMD2(env * cos(ph), env * sin(ph))
    }
  }

  // MARK: - Analytic signal and oversampling

  static func analyticSignal() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    var rng = SplitMix(seed: 11)
    let x = (0..<300).map { _ in rng.uniform() - 0.5 }
    let z = Phase.Signal.analytic(real: x, step: 1)
    log.check("Re z = x exactly (linear padding)", maxDiff(z.re, x, scale: 1) == 0, "max |Re z − x| \(fmt(maxDiff(z.re, x, scale: 1)))")

    // Whole-cycle tone, circular: cos → e^{−2πiνt} (time), e^{+ikx} (space), to round-off.
    let n = 64
    let tone = (0..<n).map { cos(2 * Double.pi * 5 * Double($0) / Double(n)) }
    let zt = Phase.Signal.analytic(real: tone, step: 1, padding: .circular)
    let zs = Phase.Signal.analytic(real: tone, step: 1, domain: .space, padding: .circular)
    var et = 0.0
    var es = 0.0
    for j in 0..<n {
      let ph = 2 * Double.pi * 5 * Double(j) / Double(n)
      et = max(et, abs(zt.re[j] - cos(ph)), abs(zt.im[j] + sin(ph)))
      es = max(es, abs(zs.re[j] - cos(ph)), abs(zs.im[j] - sin(ph)))
    }
    log.check(
      "cos → e^{−2πiνt} (time) and e^{+ikx} (space), circular", et < 1e-13 && es < 1e-13,
      "max error \(fmt(et)) (time), \(fmt(es)) (space)")

    // One-sided: the analytic tone's negative-frequency bins (convention C) are empty.
    let spec = Phase.spectrum(zt, bins: n / 2, band: .centered)
    var neg = 0.0
    var pos = 0.0
    for c in 0..<spec.power.count {
      if spec.axis.value(c) < 0 { neg += spec.power[c] } else { pos += spec.power[c] }
    }
    log.check("analytic spectrum is one-sided (ν > 0 only)", neg / pos < 1e-26, "negative/positive power \(fmt(neg / pos))")

    // 2× oversampling: passes through the samples; exact between them for a periodic band-limited signal.
    let c = packet(count: 200, step: 1, center: 100, sigma: 15, carrier: 0.2)
    let up = c.oversampled2x()
    var through = 0.0
    for j in 0..<c.count {
      through = max(through, abs(up.re[2 * j] - c.re[j]), abs(up.im[2 * j] - c.im[j]))
    }
    let periodic = Phase.Signal(count: n, step: 1) { t in
      SIMD2(cos(2 * Double.pi * 3 * t / 64) + 0.5 * cos(2 * Double.pi * 7 * t / 64 + 1), -sin(2 * Double.pi * 5 * t / 64))
    }
    let upP = periodic.oversampled2x(padding: .circular)
    var between = 0.0
    for j in 0..<(2 * n) {
      let t = Double(j) / 2
      let ex = SIMD2(cos(2 * Double.pi * 3 * t / 64) + 0.5 * cos(2 * Double.pi * 7 * t / 64 + 1), -sin(2 * Double.pi * 5 * t / 64))
      between = max(between, abs(upP.re[j] - ex.x), abs(upP.im[j] - ex.y))
    }
    log.check(
      "oversampled2x: z′[2n] = z[n]; exact between samples for a band-limited periodic record",
      through < 1e-13 && between < 1e-13 && up.count == 400 && abs(up.step - 0.5) < 1e-15,
      "through samples \(fmt(through)), between \(fmt(between))")
    return log.checks
  }

  // MARK: - Temporal marginals

  /// The M1/M2/P/reality oracles of one plane against its record.
  static func marginalChecks(
    _ log: inout PhaseCheckLog, label: String, signal z: Phase.Signal, plane w: Phase.Plane, aliasMax: Double?
  ) {
    let inten = z.intensity()
    let iPeak = inten.max() ?? 1
    let m1 = w.rowMarginal()
    let e1 = maxDiff(m1, w.rowIndices.map { inten[$0] }, scale: iPeak)
    log.check("\(label): M1 Σ_ν W dν = |z|² pointwise", e1 <= 1e-12, "max rel error \(fmt(e1))")
    let spec = Phase.spectrum(z, bins: w.columns, band: w.band)
    let m2 = w.columnMarginal()
    let peak = spec.peak
    let eId = maxDiff(m2, spec.aliased, scale: peak)
    log.check("\(label): M2 Σ_t W Δt = |Z(ν)|² + |Z(ν + period)|² pointwise", eId <= 1e-12, "max rel error \(fmt(eId))")
    let alias = (spec.alias.max() ?? 0) / peak
    let e2 = maxDiff(m2, spec.power, scale: peak)
    if let aliasMax {
      log.check(
        "\(label): M2 vs |Z|² within the alias bound (oversampled)", e2 <= alias + 1e-12 && alias <= aliasMax,
        "max rel error \(fmt(e2)) ≤ alias bound \(fmt(alias)) (≤ \(fmt(aliasMax)))")
    } else {
      log.check(
        "\(label): M2 vs |Z|² differs by exactly the alias (not oversampled)", e2 <= alias + 1e-12 && alias > 1e-3,
        "max rel error \(fmt(e2)), alias bound \(fmt(alias))")
    }
    let e = z.energy()
    let ep = abs(w.total - e) / e
    log.check("\(label): P Σ W Δt dν = Σ|z|²Δt", ep <= 1e-12, "rel error \(fmt(ep))")
    log.check("\(label): reality Im W ≈ 0", w.imaginaryResidual <= 1e-12, "max |Im|/max |Re| \(fmt(w.imaginaryResidual))")
  }

  static func temporalMarginals() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    let fs = 1000.0
    // An analytic chirped packet plus a weaker second packet (fs/8 … fs/4): oversampled in band.
    let z =
      packet(count: 256, step: 1 / fs, center: 0.1, sigma: 0.015, carrier: 120, chirp: 600)
      + packet(count: 256, step: 1 / fs, center: 0.17, sigma: 0.01, carrier: 260, amplitude: 0.6)
    let w = Phase.wigner(z)
    log.check(
      "full Wigner covers the record", w.kind == .wigner && w.coversRecord && w.columns == 256,
      "kind \(w.kind.rawValue), M = \(w.columns), rows \(w.rows)")
    marginalChecks(&log, label: "analytic packets", signal: z, plane: w, aliasMax: 1e-9)

    // Rule 1 holds for any content: white complex noise (not band limited) still has exact
    // M1 and the exact M2 alias identity; only the alias term is large.
    var rng = SplitMix(seed: 3)
    let noise = Phase.Signal(re: (0..<200).map { _ in rng.uniform() - 0.5 }, im: (0..<200).map { _ in rng.uniform() - 0.5 }, step: 1e-3)
    marginalChecks(&log, label: "white noise (M = 200)", signal: noise, plane: Phase.wigner(noise, options: Phase.WignerOptions(bins: 200)), aliasMax: nil)

    // Real stream (scope path): Wigner–Ville of a real chirp's analytic signal.
    let real = (0..<512).map { j -> Double in
      let t = Double(j) / fs
      return cos(2 * Double.pi * (40 * t + 0.5 * 600 * t * t)) * exp(-pow((t - 0.256) / 0.12, 2))
    }
    let za = Phase.Signal.analytic(real: real, step: 1 / fs)
    marginalChecks(&log, label: "Wigner–Ville of a real chirp", signal: za, plane: Phase.wignerVille(real: real, step: 1 / fs), aliasMax: 1e-4)
    return log.checks
  }

  static func spatialMarginals() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // Complex field, 2× oversampled: content within ±π/(2Δx) (centred band).
    let dx = 0.05
    let psi =
      packet(count: 400, step: dx, center: 8, sigma: 0.6, carrier: 12, chirp: 0.5, domain: .space)
      + packet(count: 400, step: dx, center: 12, sigma: 0.8, carrier: -9, domain: .space, amplitude: 0.7)
    let w = Phase.wigner(psi)
    log.check(
      "spatial Wigner: centred k band ±π/(2Δx)", w.band == .centered && abs(w.columnAxis.start + Double.pi / (2 * dx)) < 1e-9,
      "k from \(fmt(w.columnAxis.start, 5)) rad/m, step \(fmt(w.columnAxis.step, 4))")
    marginalChecks(&log, label: "2× oversampled field", signal: psi, plane: w, aliasMax: 1e-9)
    return log.checks
  }

  // MARK: - Hudson and cross terms

  static func hudsonAndCrossTerms() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // Hudson: a (chirped) Gaussian has a non-negative Wigner, in time and in space.
    let g = packet(count: 256, step: 1, center: 127.5, sigma: 12, carrier: 0.25, chirp: 4e-4)
    let wg = Phase.wigner(g)
    let gs = packet(count: 256, step: 1, center: 127.5, sigma: 12, carrier: 0.4, chirp: 2e-3, domain: .space)
    let wgs = Phase.wigner(gs)
    log.check(
      "Hudson: single chirped Gaussian ≥ 0 (time and space)",
      wg.minValue >= -1e-9 * wg.maxValue && wgs.minValue >= -1e-9 * wgs.maxValue,
      "min/max \(fmt(wg.minValue / wg.maxValue)) (time), \(fmt(wgs.minValue / wgs.maxValue)) (space)")

    // Two tones (whole bins, fs = 1, M = 256 → dν = 1/512): ν₁ = 52/512, ν₂ = 100/512.
    let n = 256
    let nu1 = 52.0 / 512
    let nu2 = 100.0 / 512
    let tones = Phase.Signal(count: n, step: 1) { t in
      SIMD2(cos(2 * Double.pi * nu1 * t) + cos(2 * Double.pi * nu2 * t), -sin(2 * Double.pi * nu1 * t) - sin(2 * Double.pi * nu2 * t))
    }
    let wt = Phase.wigner(tones, options: Phase.WignerOptions(bins: 256))
    var energy = [Double](repeating: 0, count: wt.columns)
    for r in 64..<192 {
      for c in 0..<wt.columns { energy[c] += abs(wt.value(row: r, column: c)) }
    }
    let autoCols = Set([52, 100].flatMap { ($0 - 3)...($0 + 3) })
    let cross = (0..<wt.columns).filter { !autoCols.contains($0) }.max { energy[$0] < energy[$1] }!
    let midRow = (64..<192).map { wt.value(row: $0, column: 76) }
    let autoPeak = (64..<192).map { wt.value(row: $0, column: 52) }.max()!
    let fOsc = dominantFrequency(midRow, step: 1, around: nu2 - nu1, span: 0.03)
    log.check(
      "two tones: cross term midway at (ν₁+ν₂)/2, negative",
      cross == 76 && (midRow.min() ?? 0) < -0.5 * autoPeak,
      "strongest non-auto column \(cross) (expect 76), min \(fmt(midRow.min() ?? 0)) vs auto peak \(fmt(autoPeak))")
    log.check(
      "two tones: cross term oscillates at Δν = ν₂ − ν₁ along t", rel(fOsc, nu2 - nu1) < 0.005,
      "measured \(fmt(fOsc, 6)) vs Δν \(fmt(nu2 - nu1, 6)) cycles/sample")

    // Two packets separated in time and frequency: cross term at the midpoint, oscillating at
    // Δν along t and at Δt along ν.
    let t1 = 80.0
    let t2 = 176.0
    let f1 = 0.1
    let f2 = 0.3
    let two =
      Phase.Signal(count: n, step: 1) { t in
        let e = exp(-(t - t1) * (t - t1) / (4 * 144))
        return SIMD2(e * cos(2 * Double.pi * f1 * t), -e * sin(2 * Double.pi * f1 * t))
      }
      + Phase.Signal(count: n, step: 1) { t in
        let e = exp(-(t - t2) * (t - t2) / (4 * 144))
        return SIMD2(e * cos(2 * Double.pi * f2 * t), -e * sin(2 * Double.pi * f2 * t))
      }
    let wp = Phase.wigner(two, options: Phase.WignerOptions(bins: 256))
    var minV = Double.infinity
    var at = (0, 0)
    for r in 0..<wp.rows {
      for c in 0..<wp.columns where wp.value(row: r, column: c) < minV {
        minV = wp.value(row: r, column: c)
        at = (r, c)
      }
    }
    let tMin = wp.rowAxis.value(at.0)
    let nuMin = wp.columnAxis.value(at.1)
    let midCol = wp.columnIndex((f1 + f2) / 2)
    let midT = wp.rowIndex((t1 + t2) / 2)
    let alongT = (midT - 40..<midT + 40).map { wp.value(row: $0, column: midCol) }
    let alongNu = (midCol - 60..<midCol + 60).map { wp.value(row: midT, column: $0) }
    let fT = dominantFrequency(alongT, step: 1, around: f2 - f1, span: 0.05)
    let fNu = dominantFrequency(alongNu, step: wp.columnAxis.step, around: t2 - t1, span: 30)
    log.check(
      "two packets: most negative value midway, min/max ≈ −1",
      abs(tMin - 128) <= 1 / (2 * (f2 - f1)) + 1 && abs(nuMin - 0.2) <= 1 / (2 * (t2 - t1)) + wp.columnAxis.step
        && minV / wp.maxValue < -0.8,
      "min at (t, ν) = (\(fmt(tMin, 4)), \(fmt(nuMin, 4))) vs (128, 0.2); min/max \(fmt(minV / wp.maxValue, 4))")
    log.check(
      "two packets: cross term oscillates at Δν along t and at Δt along ν", rel(fT, f2 - f1) < 0.01 && rel(fNu, t2 - t1) < 0.01,
      "along t \(fmt(fT, 5)) (Δν 0.2), along ν \(fmt(fNu, 5)) (Δt 96)")
    return log.checks
  }

  // MARK: - Chirp

  static func chirpConcentration() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // A real linear chirp 0.06 → 0.44 fs over 256 samples (a whistle / FMCW ramp), Tukey-tapered.
    let n = 256
    let fa = 0.06
    let fb = 0.44
    let alpha = (fb - fa) / Double(n)
    let real = (0..<n).map { j -> Double in
      let t = Double(j)
      let taper = tukey(j, n, 0.2)
      return taper * cos(2 * Double.pi * (fa * t + 0.5 * alpha * t * t))
    }
    let w = Phase.wignerVille(real: real, step: 1, options: Phase.WignerOptions(bins: 256))
    var near = 0.0
    var total = 0.0
    var nearAbs = 0.0
    var totalAbs = 0.0
    for r in 0..<w.rows {
      let fi = fa + alpha * Double(r)
      let ci = fi / w.columnAxis.step
      for c in 0..<w.columns {
        let v = w.value(row: r, column: c)
        total += v
        totalAbs += abs(v)
        if abs(Double(c) - ci) <= 2 {
          near += v
          nearAbs += abs(v)
        }
      }
    }
    log.check(
      "linear chirp: ≥ 90 % of the energy within ±2 bins of ν(t) = ν₀ + αt", near / total >= 0.9,
      "energy \(fmt(100 * near / total, 4)) %, |W| \(fmt(100 * nearAbs / totalAbs, 4)) % within ±2 bins")
    // The spectrogram of the same chirp at the same grid is much less concentrated.
    let s = Phase.spectrogram(Phase.Signal.analytic(real: real, step: 1), window: .hann(length: 64), bins: 256)
    var sNear = 0.0
    var sTotal = 0.0
    for r in 0..<s.rows {
      let ci = (fa + alpha * Double(r)) / s.columnAxis.step
      for c in 0..<s.columns {
        sTotal += s.value(row: r, column: c)
        if abs(Double(c) - ci) <= 2 { sNear += s.value(row: r, column: c) }
      }
    }
    log.check(
      "spectrogram of the chirp is blurred (less concentrated than the Wigner)", sNear / sTotal < near / total - 0.2,
      "spectrogram \(fmt(100 * sNear / sTotal, 3)) % within ±2 bins")
    return log.checks
  }

  static func tukey(_ j: Int, _ n: Int, _ r: Double) -> Double {
    let x = Double(j) / Double(n - 1)
    if x < r / 2 { return 0.5 * (1 - cos(2 * Double.pi * x / r)) }
    if x > 1 - r / 2 { return 0.5 * (1 - cos(2 * Double.pi * (1 - x) / r)) }
    return 1
  }

  // MARK: - Moyal

  static func moyal() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    let fs = 1000.0
    let f = packet(count: 256, step: 1 / fs, center: 0.11, sigma: 0.02, carrier: 140, chirp: 900)
    let g =
      packet(count: 256, step: 1 / fs, center: 0.13, sigma: 0.015, carrier: 150)
      + packet(count: 256, step: 1 / fs, center: 0.2, sigma: 0.01, carrier: 300, amplitude: 0.5)
    let opts = Phase.WignerOptions(bins: 256)
    let wf = Phase.wigner(f, options: opts)
    let wg = Phase.wigner(g, options: opts)
    let lhs = wf.innerProduct(wg)
    let ref = Phase.moyalReference(f, g)
    let scale = f.energy() * g.energy()
    log.check(
      "Moyal (discrete): Σ W_f W_g Δt dν = |⟨f,g⟩|² + |⟨f,(−1)ⁿg⟩|²", abs(lhs - ref.inner - ref.alias) / scale <= 1e-12,
      "error \(fmt(abs(lhs - ref.inner - ref.alias) / scale)) of ‖f‖²‖g‖²")
    log.check(
      "Moyal: |⟨f,g⟩|² = ∫∫ W_f W_g within the alias (analytic signals)",
      abs(lhs - ref.inner) / scale <= ref.alias / scale + 1e-12 && ref.alias / scale < 1e-12 && ref.inner / scale > 0.01,
      "|⟨f,g⟩|²/‖f‖²‖g‖² \(fmt(ref.inner / scale, 6)), alias \(fmt(ref.alias / scale))")
    let self2 = wf.innerProduct(wf)
    let e = f.energy()
    log.check("Moyal f = g: ∫∫ W_f² = ‖f‖⁴", abs(self2 - e * e) / (e * e) <= 1e-12, "rel error \(fmt(abs(self2 - e * e) / (e * e)))")
    // Space: same identity with the e^{−ikξ} sign.
    let p = packet(count: 200, step: 0.05, center: 4, sigma: 0.5, carrier: 10, domain: .space)
    let q = packet(count: 200, step: 0.05, center: 5, sigma: 0.7, carrier: 8, chirp: 2, domain: .space)
    let lhsS = Phase.wigner(p).innerProduct(Phase.wigner(q))
    let refS = Phase.moyalReference(p, q)
    let scaleS = p.energy() * q.energy()
    log.check(
      "Moyal in space", abs(lhsS - refS.inner - refS.alias) / scaleS <= 1e-12,
      "error \(fmt(abs(lhsS - refS.inner - refS.alias) / scaleS)), |⟨p,q⟩|² \(fmt(refS.inner / scaleS, 4))")
    return log.checks
  }

  // MARK: - Pseudo, smoothed, spectrogram

  static func pseudoSmoothedSpectrogram() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    let n = 256
    let two =
      packet(count: n, step: 1, center: 80, sigma: 12, carrier: 0.1) + packet(count: n, step: 1, center: 176, sigma: 12, carrier: 0.3)
    let inten = two.intensity()
    let pw = Phase.wigner(two, options: Phase.WignerOptions(bins: 64, lag: .hann(halfWidth: 31)))
    let e1 = maxDiff(pw.rowMarginal(), inten, scale: inten.max()!)
    log.check(
      "pseudo-Wigner (Hann lag 31, M = 64): M1 still exact", e1 <= 1e-12 && pw.kind == .pseudoWigner,
      "max rel error \(fmt(e1))")
    let g = Phase.SmoothingWindow.hann(halfWidth: 8)
    let sw = Phase.wigner(two, options: Phase.WignerOptions(bins: 64, lag: .hann(halfWidth: 31), smoothing: g))
    let gw = g.weights
    let smoothed = (0..<n).map { r -> Double in
      var s = 0.0
      for (j, wv) in gw.enumerated() {
        let idx = r - (j - 8)
        if idx >= 0 && idx < n { s += wv * inten[idx] }
      }
      return s
    }
    let e2 = maxDiff(sw.rowMarginal(), smoothed, scale: inten.max()!)
    log.check(
      "smoothed pseudo-Wigner: M1 = |z|² smoothed by the time window", e2 <= 1e-12 && sw.kind == .smoothedPseudoWigner,
      "max rel error \(fmt(e2))")
    let full = Phase.wigner(two, options: Phase.WignerOptions(bins: 256))
    let ratioFull = full.minValue / full.maxValue
    let ratioSmooth = sw.minValue / sw.maxValue
    log.check(
      "smoothing suppresses the cross term", ratioSmooth > 0.25 * ratioFull,
      "min/max \(fmt(ratioFull, 3)) (Wigner) → \(fmt(ratioSmooth, 3)) (smoothed pseudo)")

    let sp = Phase.spectrogram(two, window: .hann(length: 63), bins: 256)
    let e = two.energy()
    log.check(
      "spectrogram ≥ 0 and its total is the record energy (to the window's out-of-band leakage)",
      sp.minValue >= 0 && abs(sp.total - e) / e < 1e-6,
      "min \(fmt(sp.minValue)), total rel error \(fmt(abs(sp.total - e) / e))")

    let binned = full.binnedColumns(4)
    let e3 = maxDiff(binned.rowMarginal(), full.rowMarginal(), scale: inten.max()!)
    log.check(
      "column binning preserves M1", binned.columns == 64 && e3 <= 1e-12, "64 columns, max rel error \(fmt(e3))")

    // The Scope path: a 4096-sample real stream → 256 × 256 Wigner–Ville (4096 bins binned 16×).
    let fs = 48_000.0
    let stream = (0..<4096).map { j -> Float in
      let t = Double(j) / fs
      return Float(cos(2 * Double.pi * (1000 * t + 0.5 * 120_000 * t * t)) * tukey(j, 4096, 0.1))
    }
    let tf = Phase.timeFrequency(real: stream, sampleRate: fs)
    let e4 = maxDiff(tf.timeMarginal, tf.intensity, scale: tf.intensity.max()!)
    log.check(
      "scope Wigner–Ville 4096 → 256 × 256: M1 on every row",
      tf.plane.rows == 256 && tf.plane.columns == 256 && e4 <= 1e-12 && abs(tf.plane.columnAxis.step - fs / 2 / 256) < 1e-9,
      "\(tf.plane.rows) × \(tf.plane.columns) over 0…fs/2 (\(fmt(tf.plane.columnAxis.step, 4)) Hz columns), max rel error \(fmt(e4))")
    return log.checks
  }

  // MARK: - Aperture and Fresnel

  static func apertureAndFresnel() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // Uniform 8-element array, d = λ/2, broadside and steered 30°: k marginal vs RF array factor.
    for steer in [0.0, 30.0] {
      let n = 8
      let ap = Phase.Aperture.uniformArray(elements: n, spacing: 0.5, steerFromBroadsideDeg: steer)
      let w = ap.wigner()
      let marg = w.columnMarginal()
      let beta = RF.Arrays.steeringPhase(spacing: 0.5, steerTheta: (90 - steer) * Double.pi / 180)
      var worst = 0.0
      var count = 0
      for c in 0..<w.columns {
        let kx = w.columnAxis.value(c)
        guard abs(kx) <= ap.wavenumber else { continue }
        let thetaAxis = Double.pi / 2 - asin(kx / ap.wavenumber)
        let af = RF.Arrays.normalizedAF(theta: thetaAxis, elements: n, spacing: 0.5, beta: beta)
        // M2 = 2|Ĩ|² (two grating replicas fold into the half-lag window); |Ĩ|² = N²·AF².
        worst = max(worst, abs(marg[c] / (2 * Double(n * n)) - af * af))
        count += 1
      }
      let peak = w.columnAxis.value(marg.indices.max { marg[$0] < marg[$1] }!)
      log.check(
        "8-element array, d = λ/2, steer \(Int(steer))°: k marginal = RF array factor²",
        worst <= 1e-12 && count > 20 && abs(peak - ap.wavenumber * sin(steer * Double.pi / 180)) <= w.columnAxis.step,
        "max |Δ| \(fmt(worst)) over \(count) visible columns; peak kₓ \(fmt(peak, 4)) vs k sin θ₀ \(fmt(ap.wavenumber * sin(steer * Double.pi / 180), 4))")
    }
    // Grating lobe: d = λ, steered 30° → a full lobe at −30° (RF.Arrays.gratingLobes).
    let ga = Phase.Aperture.uniformArray(elements: 8, spacing: 1, steerFromBroadsideDeg: 30)
    let gw = ga.wigner()
    let ff = ga.farField(from: gw, anglesDeg: [30, -30, 0])
    let lobes = RF.Arrays.gratingLobes(spacing: 1, beta: RF.Arrays.steeringPhase(spacing: 1, steerTheta: 60 * Double.pi / 180))
    let rfLobe = lobes.map { 90 - $0 * 180 / Double.pi }
    log.check(
      "d = λ steered 30°: grating lobe at −30° in the far field read from the k marginal",
      ff[0].power > 0.999 && ff[1].power > 0.999 && ff[2].power < 0.05 && rfLobe.contains { abs($0 + 30) < 1e-6 },
      "power at 30°/−30°/0°: \(fmt(ff[0].power, 4))/\(fmt(ff[1].power, 4))/\(fmt(ff[2].power, 3)); RF grating lobes (from broadside) \(rfLobe.map { fmt($0, 4) })")

    // Continuous uniform aperture D = 10λ: k marginal vs the direct far-field transform.
    let cont = Phase.Aperture.continuous(width: 10, illumination: .uniform)
    let cw = cont.wigner()
    let cm = cw.columnMarginal()
    var direct: [Double] = []
    var fromW: [Double] = []
    for c in 0..<cw.columns where abs(cw.columnAxis.value(c)) <= cont.wavenumber {
      direct.append(cont.farFieldPower(kx: cw.columnAxis.value(c)))
      fromW.append(cm[c])
    }
    let dPeak = direct.max()!
    let ce = maxDiff(fromW, direct, scale: dPeak)
    let spec = Phase.spectrum(cont.current, bins: cw.columns, band: .centered)
    let alias = (spec.alias.max() ?? 0) / spec.peak
    let hp = cont.farField(from: cw).filter { $0.power >= 0.5 }.map(\.thetaDeg)
    let hpbw = (hp.max() ?? 0) - (hp.min() ?? 0)
    log.check(
      "continuous aperture D = 10λ: far field = k marginal (visible region), HPBW ≈ 50.8°/(D/λ)",
      ce <= alias + 1e-12 && alias < 1e-3 && abs(hpbw - 5.08) < 1.0,
      "max rel error \(fmt(ce)) ≤ alias \(fmt(alias)); HPBW from the marginal ≈ \(fmt(hpbw, 3))° (column-limited)")

    // Fresnel: shear of W₀ vs the Wigner of the directly propagated field (paraxial).
    let lambda = 1.0
    let k0 = 2 * Double.pi / lambda
    let dx = lambda / 4
    let beam = Phase.Signal(count: 1024, step: dx, origin: -128, domain: .space) { x in
      let env = exp(-(x + 6) * (x + 6) / (4 * 9))
      let ph = 0.08 * k0 * x
      return SIMD2(env * cos(ph), env * sin(ph))
    }
    let w0 = Phase.wigner(beam)
    for z in [40.0, 150.0, 400.0] {
      let sheared = Phase.fresnelShear(w0, distance: z, wavenumber: k0)
      let direct = Phase.wigner(Phase.fresnelPropagate(beam, distance: z, wavenumber: k0))
      let err = maxDiff(sheared.values, direct.values, scale: direct.absMax)
      log.check(
        "Fresnel shear W₀(x − zk/k₀, k) vs Wigner of the propagated field, z = \(Int(z))λ", err < 1e-6,
        "max rel error \(fmt(err)) (Fourier shift; z/z_R = \(fmt(z / (2 * k0 * 9), 3)))")
    }
    return log.checks
  }

  // MARK: - Spacetime Φ

  static func spacetime() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // A moving 2-D Gaussian packet on 48 × 48 (grid units), k₀ = 0.6 rad/sample, ν₀ = 0.22.
    let field = gatedPacketField(n: 48, k0: 0.6, nu0: 0.22, velocity: 0.5, sigmaX: 3, sigmaT: 3.2)
    let w = Phase.spacetimeWigner(field, options: Phase.SpacetimeOptions(keepFull: true, kSlice: 0.6))
    let r = Phase.marginalReport(w, field: field)
    log.check(
      "Φ grid 48 × 48 with 48 × 48 lags (exact)", w.nk == 48 && w.nnu == 48 && w.exactM2,
      "k bins \(w.nk), ν bins \(w.nnu), exact M2 \(w.exactM2)")
    log.check("Φ M1: Σ Φ dν dk/2π = |ψ|² pointwise", r.m1Error <= 1e-12, "max rel error \(fmt(r.m1Error))")
    log.check(
      "Φ M2: Σ Φ ΔxΔt = |ψ̃|² + aliases pointwise", r.m2IdentityError <= 1e-12, "max rel error \(fmt(r.m2IdentityError))")
    log.check(
      "Φ M2 vs |ψ̃(k,ν)|² within the alias bound", r.m2Error <= r.aliasLevel + 1e-12 && r.aliasLevel < 1e-6,
      "max rel error \(fmt(r.m2Error)) ≤ alias \(fmt(r.aliasLevel))")
    log.check(
      "Φ P: totals agree (Φ, |ψ|², |ψ̃|²)", r.parsevalError <= 1e-12 && r.spectralParsevalError <= 1e-12,
      "Φ vs Σ|ψ|² \(fmt(r.parsevalError)), Σ|ψ̃|² vs Σ|ψ|² \(fmt(r.spectralParsevalError))")
    log.check("marginal report badge", r.status == .consistent, "\(r.status.badge)")

    // Reality and the fast path vs a plain complex 2-D DFT at several points.
    var worstIm = 0.0
    var worstFast = 0.0
    var scale = 0.0
    for (ix, it) in [(24, 24), (10, 30), (40, 5), (0, 47), (23, 0)] {
      let ref = Phase.spacetimeWignerPoint(field, ix: ix, it: it)
      let refMax = ref.re.reduce(0) { max($0, abs($1)) }
      scale = max(scale, refMax)
      worstIm = max(worstIm, ref.im.reduce(0) { max($0, abs($1)) })
      for ck in 0..<w.nk {
        for cn in 0..<w.nnu {
          worstFast = max(worstFast, abs(ref.re[ck * w.nnu + cn] - Double(w.value(ix: ix, it: it, ck: ck, cnu: cn)!)))
        }
      }
    }
    log.check(
      "Φ is real: Im Φ ≤ 1e-12 max|Φ| (direct complex 2-D DFT)", worstIm <= 1e-12 * scale && w.imaginaryResidual <= 1e-12,
      "max |Im|/max|Re| \(fmt(worstIm / scale)); fast-path residual \(fmt(w.imaginaryResidual))")
    log.check(
      "fast symmetric path = direct 2-D DFT (Float storage)", worstFast <= 1e-6 * scale, "max rel |Δ| \(fmt(worstFast / scale))")

    // Partial marginals = the 1-D Wigners.
    var pt = 0.0
    var px = 0.0
    for ix in [3, 20, 33] {
      let one = Phase.wigner(field.timeSignal(atX: ix), options: Phase.WignerOptions(bins: 48, band: .positive))
      pt = max(pt, maxDiff(w.temporalWigner(atX: ix).values, one.values, scale: one.absMax))
    }
    for it in [5, 24, 41] {
      let one = Phase.wigner(field.spaceSignal(atT: it), options: Phase.WignerOptions(bins: 48, band: .centered))
      px = max(px, maxDiff(w.spatialWigner(atT: it).values, one.values, scale: one.absMax))
    }
    log.check(
      "partial marginals: ∫Φ dk/2π = W(t,ν) at fixed x; ∫Φ dν = W(x,k) at fixed t", pt <= 1e-12 && px <= 1e-12,
      "max rel error \(fmt(pt)) (time), \(fmt(px)) (space)")

    // k-slice cube = the slice of the full array.
    let ck = w.kSliceIndex ?? 0
    let fromFull = w.kSliceCube(column: ck + 1)
    var sliceErr = 0.0
    if let slice = w.kSlice, let full = w.full {
      for p in 0..<(48 * 48) {
        for c in 0..<w.nnu {
          sliceErr = max(sliceErr, abs(slice.values[p * w.nnu + c] - Double(full[(p * w.nk + ck) * w.nnu + c])))
        }
      }
    }
    log.check(
      "k-slice cube (x,t,ν) at k ≈ k₀ matches the stored Φ", w.kSlice != nil && fromFull != nil && sliceErr <= 1e-6 * w.maxValue
        && abs(w.kAxis.value(ck) - 0.6) <= w.kAxis.step / 2,
      "k column \(ck) = \(fmt(w.kAxis.value(ck), 4)) rad/sample, max |Δ| \(fmt(sliceErr / w.maxValue)) of max Φ")

    // Hudson in spacetime: a single Gaussian packet's Φ is non-negative (the packet decays to
    // 1e-12 at the grid edges, so no lag is cut short).
    let hudson = Phase.spacetimeWigner(gatedPacketField(n: 48, k0: 0, nu0: 0.25, velocity: 0.5, sigmaX: 2, sigmaT: 2))
    log.check(
      "Hudson: single Gaussian packet Φ ≥ −1e-9 max Φ", hudson.minValue >= -1e-9 * hudson.maxValue,
      "min/max \(fmt(hudson.minValue / hudson.maxValue)) (48⁴ values)")

    // Two packets (sources A and B, same envelope, carriers k = ∓0.5 rad, ν = 0.125 and 0.3125):
    // the cross term sits at the midpoint (k, ν) = (0, 0.21875), negative, beating at Δν in t.
    let a = gatedPacketField(n: 48, k0: -0.5, nu0: 0.125, velocity: 0.5, sigmaX: 3, sigmaT: 3.2)
    let b = gatedPacketField(n: 48, k0: 0.5, nu0: 0.3125, velocity: 0.5, sigmaX: 3, sigmaT: 3.2)
    let two = a + b
    let w2 = Phase.spacetimeWigner(two, options: Phase.SpacetimeOptions(keepFull: true))
    let kMin = w2.kAxis.value(w2.argMin[2])
    let nuMin = w2.nuAxis.value(w2.argMin[3])
    let ratio = w2.minValue / w2.maxValue
    log.check(
      "two packets: Φ has a negative cross term at the (k, ν) midpoint, as deep as the auto terms",
      abs(kMin) <= w2.kAxis.step / 2 && abs(nuMin - 0.21875) <= w2.nuAxis.step / 2 && ratio < -0.5,
      "min at (k, ν) = (\(fmt(kMin, 3)), \(fmt(nuMin, 4))) vs (0, 0.21875); min/max \(fmt(ratio, 4))")
    let ckMid = w2.kAxis.nearestIndex(0)
    let cnMid = w2.nuAxis.nearestIndex(0.21875)
    let beat = (0..<48).map { it in w2.value(ix: 24, it: it, ck: ckMid, cnu: cnMid)! }
    let fBeat = dominantFrequency(Array(beat[6..<42]), step: 1, around: 0.1875, span: 0.06)
    // At fixed x the cross term ∝ cos(Δk x − 2πΔν t): it beats at Δν = 0.1875 along t.
    log.check(
      "two packets: cross term oscillates at Δν = ν_B − ν_A along t (fixed x)", rel(fBeat, 0.1875) < 0.03,
      "measured \(fmt(fBeat, 4)) vs 0.1875 cycles/sample")
    let r2 = Phase.marginalReport(w2, field: two)
    log.check(
      "two packets: marginals still exact", r2.m1Error <= 1e-12 && r2.m2IdentityError <= 1e-12 && r2.parsevalError <= 1e-12,
      "M1 \(fmt(r2.m1Error)), M2 \(fmt(r2.m2IdentityError)), P \(fmt(r2.parsevalError))")

    // Pseudo windows: M1 and P stay exact, M2 smoothed (status SMOOTHED).
    let pw = Phase.spacetimeWigner(field, options: Phase.SpacetimeOptions(lagX: .hann(halfWidth: 12), lagT: .hann(halfWidth: 12)))
    let pr = Phase.marginalReport(pw, field: field)
    log.check(
      "pseudo Φ (Hann lags 12): M1 and P exact, badge SMOOTHED", pr.m1Error <= 1e-12 && pr.parsevalError <= 1e-12 && pr.status == .smoothed,
      "M1 \(fmt(pr.m1Error)), P \(fmt(pr.parsevalError)), M2 smoothed by \(fmt(pr.m2Error))")
    return log.checks
  }

  // MARK: - Packets and dispersion

  static func packetsAndDispersion() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    let c = SI.c
    // Shells.
    let vac = Phase.Dispersion.vacuum
    log.check(
      "vacuum light line ν = c|k|/2π, v_g = c",
      rel(vac.frequency(wavenumber: -2e7)!, c * 2e7 / (2 * Double.pi)) < 1e-15 && vac.groupVelocity(frequency: 5e14)! == c,
      "ν(−2e7 rad/m) = \(fmt(vac.frequency(wavenumber: -2e7)!, 8)) Hz")
    let glass = Phase.Dispersion.medium(.glass)
    let nu550 = c / 550e-9
    let nCore = Matter.Medium.glass.index(550e-9).n
    let k550 = glass.wavenumber(frequency: nu550)!
    let back = glass.frequency(wavenumber: k550)!
    // Group index n_g = n − λ dn/dλ from Core by finite differences (independent of dk/dν).
    let h = 1e-12
    let dndl = (Matter.Medium.glass.index(550e-9 + h).n - Matter.Medium.glass.index(550e-9 - h).n) / (2 * h)
    let ng = nCore - 550e-9 * dndl
    let vg = glass.groupVelocity(frequency: nu550)!
    log.check(
      "BK7 shell: k = n(λ)ω/c with Core's Sellmeier, inverse round trip, v_g = c/n_g",
      abs(nCore - 1.51852) < 5e-5 && rel(k550, 2 * Double.pi * nCore / 550e-9) < 1e-14 && rel(back, nu550) < 1e-12
        && rel(c / vg, ng) < 1e-5 && ng > 1.54 && ng < 1.55,
      "n \(fmt(nCore, 6)), ν round trip \(fmt(rel(back, nu550))), n_g \(fmt(c / vg, 6)) vs \(fmt(ng, 6))")
    let water = Phase.Dispersion.medium(.water)
    let nW = water.refractiveIndex(frequency: c / 500e-9)
    log.check(
      "water shell (Cauchy, Core): n(500 nm) = 1.3251 + 2946/500²", abs(nW.n - (1.3251 + 2946.0 / 250_000)) < 1e-12 && nW.valid,
      "n \(fmt(nW.n, 7))")
    let fp = 9e6
    let plasma = Phase.Dispersion.plasma(plasmaFrequency: fp)
    let f = 15e6
    let kp = plasma.wavenumber(frequency: f)!
    let vgp = plasma.groupVelocity(frequency: f)!
    let vpp = plasma.phaseVelocity(frequency: f)!
    log.check(
      "plasma ω² = ω_p² + c²k²: v_g v_p = c², v_g = c√(1 − f_p²/f²), cut-off below f_p",
      rel(vgp * vpp, c * c) < 1e-14 && rel(vgp, c * (1 - fp * fp / (f * f)).squareRoot()) < 1e-14
        && plasma.wavenumber(frequency: 8e6) == nil && rel(plasma.frequency(wavenumber: kp)!, f) < 1e-14,
      "v_g \(fmt(vgp / c, 6)) c, v_p \(fmt(vpp / c, 6)) c")
    let fc = c / (2 * 22.86e-3)
    let wg = Phase.Dispersion.waveguide(cutoffFrequency: fc)
    let lg = 2 * Double.pi / wg.wavenumber(frequency: 10e9)!
    log.check(
      "WR-90 waveguide: f_c = 6.557 GHz, λ_g = λ/√(1 − (f_c/f)²) at 10 GHz",
      abs(fc / 1e9 - 6.557) < 1e-3 && rel(lg, (c / 10e9) / (1 - fc * fc / 1e20).squareRoot()) < 1e-14,
      "f_c \(fmt(fc / 1e9, 5)) GHz, λ_g \(fmt(lg * 1000, 5)) mm")
    let tp = plasma.taylor(atFrequency: f)!
    let dk = tp.k0 * 1e-4
    let numGvd =
      (plasma.angularFrequency(wavenumber: tp.k0 + dk)! - 2 * plasma.angularFrequency(wavenumber: tp.k0)!
        + plasma.angularFrequency(wavenumber: tp.k0 - dk)!) / (dk * dk)
    log.check(
      "plasma Taylor model: D = c²ω_p²/ω³ matches d²ω/dk²", rel(tp.gvd, numGvd) < 1e-5, "D \(fmt(tp.gvd, 6)) vs \(fmt(numGvd, 6)) m²/s")

    // Closed-form Gaussian Wigner vs numeric: vacuum (display units, any band), chirped packet.
    let units = Phase.DisplayUnits(referenceWavelength: 550e-9)
    let model = Phase.ShellModel(.vacuum, units: units)
    let pk = Phase.GaussianPacket(carrierFrequency: 1, width: 2, chirp: 0.05, center: -3)
    let taylor = model.taylor(atFrequency: 1)!
    let xAxis = Phase.Axis(start: -32, step: 1.0 / 8, count: 512)
    let t = 3.0
    let pf = Phase.packetField([pk], model: model, x: xAxis, t: Phase.Axis(start: t, step: 1, count: 1))
    let wNum = Phase.wigner(pf.field.spaceSignal(atT: 0))
    var cf = [Double](repeating: 0, count: wNum.values.count)
    for r in 0..<wNum.rows {
      for cc in 0..<wNum.columns {
        cf[r * wNum.columns + cc] = pk.closedFormSpatialWigner(
          x: wNum.rowAxis.value(r), k: wNum.columnAxis.value(cc), t: t, taylor: taylor)
      }
    }
    let eSpace = maxDiff(wNum.values, cf, scale: cf.max()!)
    log.check(
      "closed-form W(x,k;t) of a chirped Gaussian in vacuum vs numeric", eSpace < 1e-10 && abs(taylor.groupVelocity - 1) < 1e-12,
      "max rel error \(fmt(eSpace)) (display units: x in λ, k in rad/λ; v_g = \(fmt(taylor.groupVelocity, 4)) c)")
    // Temporal closed form at fixed x.
    let tAxis = Phase.Axis(start: 0, step: 1.0 / 8, count: 512)
    let pT = Phase.GaussianPacket(carrierFrequency: 1, width: 2, chirp: 0.05, center: -30)
    let pfT = Phase.packetField([pT], model: model, x: Phase.Axis(start: 2, step: 1, count: 1), t: tAxis)
    let wT = Phase.wigner(pfT.field.timeSignal(atX: 0))
    var cfT = [Double](repeating: 0, count: wT.values.count)
    for r in 0..<wT.rows {
      for cc in 0..<wT.columns {
        cfT[r * wT.columns + cc] = pT.closedFormTemporalWigner(t: wT.rowAxis.value(r), nu: wT.columnAxis.value(cc), x: 2, taylor: taylor)!
      }
    }
    let eTime = maxDiff(wT.values, cfT, scale: cfT.max()!)
    log.check("closed-form W(t,ν;x) at fixed x (linear dispersion) vs numeric", eTime < 1e-10, "max rel error \(fmt(eTime))")
    // Quadratic dispersion: the Wigner shears along v_g + D(k − k₀) (exact transport).
    let quad = Phase.Dispersion.Taylor(k0: 2 * Double.pi, omega0: 2 * Double.pi, groupVelocity: 0.8, gvd: 0.3)
    let qModel = Phase.ShellModel(.taylor(quad))
    let pq = Phase.GaussianPacket(carrierFrequency: 1, width: 1.5, center: -6)
    let pfq = Phase.packetField([pq], model: qModel, x: xAxis, t: Phase.Axis(start: 6, step: 1, count: 1))
    let wq = Phase.wigner(pfq.field.spaceSignal(atT: 0))
    var cfq = [Double](repeating: 0, count: wq.values.count)
    for r in 0..<wq.rows {
      for cc in 0..<wq.columns {
        cfq[r * wq.columns + cc] = pq.closedFormSpatialWigner(x: wq.rowAxis.value(r), k: wq.columnAxis.value(cc), t: 6, taylor: quad)
      }
    }
    let eQuad = maxDiff(wq.values, cfq, scale: cfq.max()!)
    log.check("quadratic dispersion: numeric W = sheared closed form", eQuad < 1e-9, "max rel error \(fmt(eQuad))")

    // Group velocity in the field: plasma (f = 1.5 f_p) and glass packets travel at v_g.
    for (name, disp, ref) in [
      ("plasma f = 1.5 f_p", Phase.Dispersion.plasma(plasmaFrequency: 2e14), 3e14),
      ("BK7 glass", Phase.Dispersion.medium(.glass), c / 550e-9),
    ] {
      let u = Phase.DisplayUnits(referenceFrequency: ref)
      let m = Phase.ShellModel(disp, units: u)
      let p = Phase.GaussianPacket(carrierFrequency: 1, width: 3, center: -8)
      let vgExpected = m.groupVelocity(1)!
      let field = Phase.packetField([p], model: m, x: Phase.Axis(start: -24, step: 0.1, count: 480), t: Phase.Axis(start: 0, step: 4, count: 5))
      let centroids = (0..<5).map { it -> Double in
        let s = field.field.spaceSignal(atT: it)
        let inten = s.intensity()
        return zip(inten, s.axis.values).map(*).reduce(0, +) / inten.reduce(0, +)
      }
      let slope = (centroids[4] - centroids[0]) / 16
      log.check(
        "\(name): packet centroid moves at v_g", rel(slope, vgExpected) < 2e-3,
        "measured \(fmt(slope, 5)) c vs v_g \(fmt(vgExpected, 5)) c")
    }

    // Shell support: M2 of a glass packet lies on ν(k) (rule 6).
    let scene = Phase.phaseSpaceScene(
      Phase.PhaseSpaceRequest(
        packets: [Phase.GaussianPacket.fromSource(lambda: 550e-9, cycles: 4, model: Phase.ShellModel(.medium(.glass), units: units))!],
        dispersion: .medium(.glass), referenceFrequency: c / 550e-9))
    let m2 = scene.wigner.m2Grid
    var on2 = 0.0
    var on3 = 0.0
    var all = 0.0
    for ck in 0..<m2.rowAxis.count {
      let nuShell = scene.model.frequency(m2.rowAxis.value(ck))
      for cn in 0..<m2.columnAxis.count {
        let v = m2.value(row: ck, column: cn)
        all += v
        guard let nuShell else { continue }
        let d = abs(m2.columnAxis.value(cn) - nuShell) / m2.columnAxis.step
        if d <= 2 { on2 += v }
        if d <= 3 { on3 += v }
      }
    }
    log.check(
      "glass packet scene: M2 lies on the Sellmeier shell ν(k) (≥ 90 % within ±3 ν bins); report CONSISTENT",
      on3 / all >= 0.9 && scene.report.status == .consistent,
      "\(fmt(100 * on2 / all, 4)) % within ±2 bins, \(fmt(100 * on3 / all, 4)) % within ±3 (Hann window: 2 bins); \(scene.report.status.badge), alias \(fmt(scene.report.aliasLevel))")

    // Display units: the same packets at radio and at visible give the same picture.
    let pA = Phase.GaussianPacket(carrierFrequency: 1, width: 1.5, center: -1)
    let pB = Phase.GaussianPacket(carrierFrequency: 1.4, width: 1.2, center: 1)
    let radio = Phase.phaseSpaceScene(Phase.PhaseSpaceRequest(packets: [pA, pB], dispersion: .vacuum, referenceFrequency: 2.4e9))
    let light = Phase.phaseSpaceScene(Phase.PhaseSpaceRequest(packets: [pA, pB], dispersion: .vacuum, referenceFrequency: c / 550e-9))
    let eUnits = maxDiff(radio.field.re, light.field.re, scale: 1)
    log.check(
      "display units: identical scene at 2.4 GHz and 550 nm", eUnits < 1e-12 && radio.wigner.nk == light.wigner.nk,
      "max |Δψ| \(fmt(eUnits)); λ_ref \(fmt(radio.units.wavelength, 4)) m vs \(fmt(light.units.wavelength, 4)) m")
    let ratio2 = radio.wigner.minValue / radio.wigner.maxValue
    log.check(
      "sources A + B: cross term negative in the scene; report CONSISTENT", ratio2 < -0.3 && radio.report.status == .consistent,
      "min/max \(fmt(ratio2, 3)), \(radio.report.status.badge)")
    // Below cut-off: no field and a note.
    let cut = Phase.phaseSpaceScene(
      Phase.PhaseSpaceRequest(packets: [pA], dispersion: .plasma(plasmaFrequency: 10e6), referenceFrequency: 5e6))
    log.check(
      "plasma below cut-off: packet dropped with a note", cut.carriers.first! == nil && !cut.notes.isEmpty && cut.field.energy() == 0,
      cut.notes.first ?? "")
    return log.checks
  }

  // MARK: - Timing

  /// Best of `repeats` runs: this thread's CPU time and the wall time of that run, in ms. The
  /// budget is checked on CPU time (what the work costs), which other processes on a busy
  /// machine cannot inflate; the wall time is reported alongside.
  static func bestTime(_ repeats: Int, _ body: () -> Void) -> (cpu: Double, wall: Double) {
    var best = (cpu: Double.infinity, wall: Double.infinity)
    for _ in 0..<repeats {
      let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      let t0 = Date()
      body()
      let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1e6
      if cpu < best.cpu { best = (cpu, Date().timeIntervalSince(t0) * 1000) }
    }
    return best
  }

  static func ms(_ t: (cpu: Double, wall: Double)) -> String { "\(fmt(t.cpu, 3)) ms CPU (\(fmt(t.wall, 3)) ms wall)" }

  static func timing() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    // Budgets for optimized builds; an unoptimized (Debug XCTest) build gets 30× slack.
    let slack: Double = _isDebugAssertConfiguration() ? 30 : 1
    let real = (0..<256).map { j -> Double in cos(2 * Double.pi * (0.05 * Double(j) + 0.0007 * Double(j * j))) }
    var plane: Phase.Plane?
    let tWV = bestTime(5) { plane = Phase.wignerVille(real: real, step: 1) }
    log.check(
      "Wigner–Ville 256 × 256 (analytic + WVD)", tWV.cpu < 5 * slack && plane?.values.count == 256 * 256,
      "\(ms(tWV)), budget \(fmt(5 * slack, 3)) ms")
    let z = Phase.Signal.analytic(real: real, step: 1)
    let tSP = bestTime(5) { plane = Phase.spectrogram(z, window: .hann(length: 64), bins: 256) }
    log.check("spectrogram 256 × 256", tSP.cpu < 5 * slack, "\(ms(tSP)), budget \(fmt(5 * slack, 3)) ms")
    let tSPW = bestTime(3) {
      plane = Phase.wigner(z, options: Phase.WignerOptions(bins: 256, lag: .hann(halfWidth: 127), smoothing: .hann(halfWidth: 8)))
    }
    log.check("smoothed pseudo-Wigner 256 × 256 (time window ±8)", tSPW.cpu < 15 * slack, "\(ms(tSPW)), budget \(fmt(15 * slack, 3)) ms")
    let stream = (0..<4096).map { Float(sin(0.001 * Double($0 * $0 % 100_000))) }
    var tf: Phase.TimeFrequencyImage?
    let tScope = bestTime(3) { tf = Phase.timeFrequency(real: stream, sampleRate: 48_000) }
    log.check(
      "scope: 4096-sample stream → 256 × 256 Wigner–Ville (4096 bins, binned 16×)", tScope.cpu < 30 * slack && tf?.plane.columns == 256,
      "\(ms(tScope)), budget \(fmt(30 * slack, 3)) ms")
    let field = gatedPacketField(n: 48, k0: 0.6, nu0: 0.22, velocity: 0.5, sigmaX: 3, sigmaT: 3.2)
    var st: Phase.SpacetimeWigner?
    let tPhi = bestTime(3) { st = Phase.spacetimeWigner(field) }
    log.check(
      "spacetime Φ: 48 × 48 grid × 48 × 48 lags (5.3 M values)", tPhi.cpu < 250 * slack && st?.nk == 48,
      "\(ms(tPhi)), budget \(fmt(250 * slack, 4)) ms")
    let tFull = bestTime(2) { st = Phase.spacetimeWigner(field, options: Phase.SpacetimeOptions(keepFull: true)) }
    log.check("Φ with the full 4-D array kept (21 MB Float)", tFull.cpu < 300 * slack, "\(ms(tFull)), budget \(fmt(300 * slack, 4)) ms")
    var scene: Phase.PhaseSpaceScene?
    let req = Phase.PhaseSpaceRequest(
      packets: [
        Phase.GaussianPacket(carrierFrequency: 1, width: 1.5, center: -1), Phase.GaussianPacket(carrierFrequency: 1.4, width: 1.2, center: 1),
      ],
      dispersion: .medium(.glass), referenceFrequency: SI.c / 550e-9)
    let tScene = bestTime(2) { scene = Phase.phaseSpaceScene(req) }
    log.check(
      "Phase space scene (two packets in glass: field + Φ + report)", tScene.cpu < 300 * slack && scene != nil,
      "\(ms(tScene)), budget \(fmt(300 * slack, 4)) ms")
    return log.checks
  }

  // MARK: - Robustness

  static func robustness() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    let empty = Phase.wigner(Phase.Signal(re: [], im: [], step: 1))
    let one = Phase.wigner(Phase.Signal(re: [2], im: [0], step: 1))
    log.check(
      "empty and single-sample records", empty.isEmpty && one.rows == 1 && abs(one.rowMarginal()[0] - 4) < 1e-12,
      "empty → \(empty.values.count) values; one sample M1 \(fmt(one.rowMarginal()[0]))")
    var s = packet(count: 128, step: 1, center: 64, sigma: 10, carrier: 0.2)
    s.re[40] = .nan
    s.im[90] = .infinity
    let w = Phase.wigner(s)
    log.check("non-finite samples are zeroed, not spread", w.values.allSatisfy(\.isFinite), "all \(w.values.count) values finite")
    let odd = Phase.wigner(packet(count: 30, step: 1, center: 15, sigma: 4, carrier: 0.2), options: Phase.WignerOptions(bins: 13))
    let z12 = packet(count: 20, step: 1, center: 10, sigma: 3, carrier: 0.15)
    let w12 = Phase.wigner(z12, options: Phase.WignerOptions(bins: 12))
    let e12 = maxDiff(w12.rowMarginal(), z12.intensity(), scale: 1)
    log.check(
      "odd bins round up to even; non-vDSP length (12) uses the exact fallback", odd.columns == 14 && e12 < 1e-12,
      "13 → \(odd.columns) columns; M = 12 M1 error \(fmt(e12))")
    let ff = Phase.spacetimeWigner(Phase.Field(re: [], im: [], x: Phase.Axis(start: 0, step: 1, count: 0), t: Phase.Axis(start: 0, step: 1, count: 0)))
    log.check("empty spacetime field", ff.m1.isEmpty && ff.total == 0, "M1 \(ff.m1.count) values")

    // Absurd sizes clamp instead of trapping (bins + 1 overflow, Int(1e300), Int.max counts).
    let huge = Phase.wigner(Phase.Signal(re: [1, 2, 3], im: [0, 1, 0], step: 1), options: Phase.WignerOptions(bins: Int.max))
    let eHuge = maxDiff(huge.rowMarginal(), [1, 5, 9], scale: 9)
    let noBins = Phase.spectrum(Phase.Signal(re: [1], im: [0], step: 1), bins: 0, band: .positive)
    let wideArray = Phase.Aperture.uniformArray(elements: Int.max, spacing: 0.5, samplesPerElement: Int.max, guardElements: Int.max)
    let axis = Phase.Axis(start: 0, step: 1, count: 10)
    log.check(
      "bins Int.max, spectrum bins 0, uniformArray(Int.max…), nearestIndex(±1e300) do not trap",
      huge.columns == Phase.maxBins && eHuge < 1e-12 && noBins.power.isEmpty && wideArray.current.count > 0
        && axis.nearestIndex(1e300) == 9 && axis.nearestIndex(-1e300) == 0 && axis.nearestIndex(.nan) == 0,
      "M = \(huge.columns), M1 error \(fmt(eHuge)); aperture \(wideArray.current.count) samples")
    log.check(
      "long records keep rows × M ≤ maxPlaneValues (rows spread evenly)",
      Phase.boundedRows(.all, samples: 100_000, columns: 65_536).count == Phase.maxPlaneValues / 65_536
        && Phase.boundedRows(.all, samples: 256, columns: 256).count == 256,
      "100 000 samples × 65 536 columns → \(Phase.boundedRows(.all, samples: 100_000, columns: 65_536).count) rows")

    // A stream whose rate is 0, NaN or negative (BLE RSSI has nominal rate 0) gives an empty,
    // finite image, never NaN.
    let ramp = (0..<128).map { Float(sin(0.3 * Double($0))) }
    let bad = [0.0, .nan, -48_000].map { Phase.timeFrequency(real: ramp, sampleRate: $0) }
    log.check(
      "time–frequency of a stream without a valid rate: empty image, no NaN",
      bad.allSatisfy { $0.plane.isEmpty && $0.spectrum.isEmpty && $0.plane.columnMeasure.isFinite },
      bad.map { "\($0.plane.rows)×\($0.plane.columns)" }.joined(separator: ", "))

    // One NaN in an I + jQ record must not blank (or NaN) the whole oversampled image.
    var iq = Phase.Signal(count: 256, step: 1e-3) { t in SIMD2(cos(2 * Double.pi * 100 * t), -sin(2 * Double.pi * 100 * t)) }
    iq.re[40] = .nan
    let tfNaN = Phase.timeFrequency(complex: iq, request: Phase.TimeFrequencyRequest(rows: 64, columns: 64))
    log.check(
      "complex record with a NaN sample: finite, non-blank image and strips",
      tfNaN.plane.values.allSatisfy(\.isFinite) && tfNaN.plane.absMax > 0 && tfNaN.intensity.allSatisfy(\.isFinite)
        && tfNaN.spectrum.allSatisfy(\.isFinite),
      "max |W| \(fmt(tfNaN.plane.absMax))")

    // NaN window parameters fall back to finite windows.
    let zz = Phase.Signal(count: 32, step: 1) { t in SIMD2(cos(0.3 * t), -sin(0.3 * t)) }
    let nanWindows = [
      Phase.wigner(zz, options: Phase.WignerOptions(lag: .gaussian(halfWidth: 5, sigma: .nan))),
      Phase.wigner(zz, options: Phase.WignerOptions(smoothing: .gaussian(halfWidth: 3, sigma: .nan))),
      Phase.spectrogram(zz, window: .gaussian(length: 16, sigma: .nan), bins: 32),
    ]
    log.check("Gaussian windows with σ = NaN stay finite", nanWindows.allSatisfy { $0.values.allSatisfy(\.isFinite) }, "3 planes")

    // Marginal report: NaN samples are zeroed as in Φ; a folded spectrum (bins < N/2) is a pseudo
    // Φ (SMOOTHED), not a failed identity; a report against another grid does not trap.
    var fNaN = gatedPacketField(n: 20, k0: 0.5, nu0: 0.2, velocity: 0.5, sigmaX: 3, sigmaT: 3)
    fNaN.re[33] = .nan
    let rNaN = Phase.marginalReport(Phase.spacetimeWigner(fNaN), field: fNaN)
    let fSmall = gatedPacketField(n: 20, k0: 0.5, nu0: 0.2, velocity: 0.5, sigmaX: 3, sigmaT: 3)
    let rFold = Phase.marginalReport(Phase.spacetimeWigner(fSmall, options: Phase.SpacetimeOptions(kBins: 8, nuBins: 8)), field: fSmall)
    let rWrong = Phase.marginalReport(Phase.spacetimeWigner(fSmall), field: gatedPacketField(n: 12, k0: 0.5, nu0: 0.2, velocity: 0.5, sigmaX: 3, sigmaT: 3))
    log.check(
      "marginal report: NaN sample zeroed, folded pseudo Φ SMOOTHED, mismatched grid INCONSISTENT",
      rNaN.m1Error <= 1e-12 && rNaN.parsevalError <= 1e-12 && rNaN.m2IdentityError <= 1e-12 && rFold.status == .smoothed
        && rFold.spectralParsevalError <= 1e-12 && rWrong.status == .inconsistent,
      "NaN field M1 \(fmt(rNaN.m1Error)); folded \(rFold.status.badge) (spectral P \(fmt(rFold.spectralParsevalError))); mismatch \(rWrong.status.badge)")

    // Fresnel with an undefined distance or wavenumber: identity, not NaN or blank.
    let beam = Phase.Signal(count: 64, step: 0.25, origin: -8, domain: .space) { x in SIMD2(exp(-x * x / 4), 0) }
    let wb = Phase.wigner(beam)
    let id1 = Phase.fresnelShear(wb, distance: .nan, wavenumber: 6)
    let id2 = Phase.fresnelShear(wb, distance: 3, wavenumber: 0, model: .angularSpectrum)
    let id3 = Phase.fresnelPropagate(beam, distance: .nan, wavenumber: 6)
    let id4 = Phase.fresnelPropagate(beam, distance: 3, wavenumber: -1)
    let eId = max(
      maxDiff(id1.values, wb.values, scale: wb.absMax), maxDiff(id2.values, wb.values, scale: wb.absMax),
      maxDiff(id3.re, beam.re, scale: 1), maxDiff(id4.re, beam.re, scale: 1))
    log.check("Fresnel with z = NaN or k₀ ≤ 0 is the identity", eId < 1e-12, "max deviation \(fmt(eId))")

    // Scene: invalid packets and packets far outside the window get a note, never NaN.
    let sceneBad = Phase.phaseSpaceScene(
      Phase.PhaseSpaceRequest(
        packets: [Phase.GaussianPacket(carrierFrequency: 1, width: 0), Phase.GaussianPacket(carrierFrequency: .nan, width: 1)],
        dispersion: .vacuum, referenceFrequency: 5e14, gridSize: 16))
    let sceneFar = Phase.phaseSpaceScene(
      Phase.PhaseSpaceRequest(
        packets: [Phase.GaussianPacket(carrierFrequency: 1, width: 1.5, center: 1e300)], dispersion: .vacuum, referenceFrequency: 5e14,
        gridSize: 16))
    let sceneRef = Phase.phaseSpaceScene(
      Phase.PhaseSpaceRequest(packets: [Phase.GaussianPacket(carrierFrequency: 1, width: 1.5)], dispersion: .vacuum, referenceFrequency: .nan, gridSize: 16))
    log.check(
      "scene: invalid packets, a packet far outside, an invalid reference → notes, finite field",
      sceneBad.notes.count == 2 && sceneBad.carriers.allSatisfy { $0 == nil } && sceneBad.wigner.m1.allSatisfy(\.isFinite)
        && sceneFar.field.energy() == 0 && sceneFar.notes.contains { $0.contains("outside") } && sceneRef.notes.count == 1
        && sceneRef.field.re.allSatisfy(\.isFinite) && Phase.phaseSpaceScene(
          Phase.PhaseSpaceRequest(packets: [], dispersion: .vacuum, referenceFrequency: 5e14, gridSize: 0)).field.nx == 8,
      (sceneBad.notes + sceneFar.notes + sceneRef.notes).joined(separator: " / "))
    return log.checks
  }

  // MARK: - Independent references

  /// Direct-sum 1-D Wigner written from convention (C), no engine transform: for each row n,
  /// W(ν) = 2Δ Σ_{|m| ≤ L} h(|m|) z*[n−m] z[n+m] e^{+2πiν·2mΔ} (time) or e^{−ik·2mΔ} (space).
  static func directWigner(_ z: Phase.Signal, rows: [Int], columns: [Double], lagCap: Int, h: (Int) -> Double = { _ in 1 }) -> [Double] {
    var out = [Double](repeating: 0, count: rows.count * columns.count)
    for (r, n) in rows.enumerated() {
      for (c, v) in columns.enumerated() {
        var acc = 0.0
        for m in -lagCap...lagCap {
          let a = n - m
          let b = n + m
          guard a >= 0, b >= 0, a < z.count, b < z.count else { continue }
          let pr = z.re[a] * z.re[b] + z.im[a] * z.im[b]
          let pi = z.re[a] * z.im[b] - z.im[a] * z.re[b]
          let ph = z.domain == .time ? 2 * Double.pi * v * 2 * Double(m) * z.step : -v * 2 * Double(m) * z.step
          acc += h(abs(m)) * (pr * cos(ph) - pi * sin(ph))
        }
        out[r * columns.count + c] = 2 * z.step * acc
      }
    }
    return out
  }

  /// The column values an M-bin Wigner must have, derived here: the half-lag Wigner repeats every
  /// fs/2 (π/Δx), split into M columns; positive band s = c, centred s = c − M/2.
  static func expectedColumns(domain: Phase.Domain, step: Double, bins m: Int, centred: Bool) -> [Double] {
    let period = domain == .time ? 1 / (2 * step) : Double.pi / step
    return (0..<m).map { Double(centred ? $0 - m / 2 : $0) * period / Double(m) }
  }

  /// Direct-sum Φ at one grid point (convention C, no engine transform).
  static func directPhi(
    _ f: Phase.Field, ix: Int, it: Int, k: [Double], nu: [Double], capX: Int, capT: Int
  ) -> [Double] {
    var out = [Double](repeating: 0, count: k.count * nu.count)
    let dx = f.xAxis.step
    let dt = f.tAxis.step
    for a in -capX...capX {
      for b in -capT...capT {
        let x1 = ix - a
        let x2 = ix + a
        let t1 = it - b
        let t2 = it + b
        guard x1 >= 0, x2 >= 0, x1 < f.nx, x2 < f.nx, t1 >= 0, t2 >= 0, t1 < f.nt, t2 < f.nt else { continue }
        let p1 = x1 * f.nt + t1
        let p2 = x2 * f.nt + t2
        let pr = f.re[p1] * f.re[p2] + f.im[p1] * f.im[p2]
        let pi = f.re[p1] * f.im[p2] - f.im[p1] * f.re[p2]
        for (ck, kv) in k.enumerated() {
          for (cn, nv) in nu.enumerated() {
            let ph = -kv * 2 * Double(a) * dx + 2 * Double.pi * nv * 2 * Double(b) * dt
            out[ck * nu.count + cn] += 4 * dx * dt * (pr * cos(ph) - pi * sin(ph))
          }
        }
      }
    }
    return out
  }

  /// Gaussian beam e^{−(x−x₀)²/(4σ²) + i k_c x}: its exact Wigner, √(8πσ²) e^{−(x−x₀)²/(2σ²) − 2σ²(k − k_c)²}.
  static func gaussianBeamWigner(x: Double, k: Double, x0: Double, sigma2: Double, kc: Double) -> Double {
    (8 * Double.pi * sigma2).squareRoot() * exp(-(x - x0) * (x - x0) / (2 * sigma2) - 2 * sigma2 * (k - kc) * (k - kc))
  }

  static func independentReferences() -> [PhaseCheck] {
    var log = PhaseCheckLog()
    var rng = SplitMix(seed: 2026)
    // DFT lengths beyond the conventions group: 4 and 8 (smallest vDSP), 60 (15·4 is not vDSP:
    // fallback), 7 (odd fallback), 120 (15·8, vDSP).
    var worstDFT = 0.0
    for n in [4, 7, 8, 60, 120] {
      let re = (0..<n).map { _ in rng.uniform() - 0.5 }
      let im = (0..<n).map { _ in rng.uniform() - 0.5 }
      let (fr, fi) = Phase.DFT(count: n).transform(.positive, re: re, im: im)
      for q in 0..<n {
        var ar = 0.0
        var ai = 0.0
        for j in 0..<n {
          let ph = 2 * Double.pi * Double((q * j) % n) / Double(n)
          ar += re[j] * cos(ph) - im[j] * sin(ph)
          ai += re[j] * sin(ph) + im[j] * cos(ph)
        }
        worstDFT = max(worstDFT, abs(fr[q] - ar), abs(fi[q] - ai))
      }
    }
    log.check("DFT N = 4, 7, 8, 60, 120 (vDSP and fallback) vs direct sums", worstDFT < 1e-12, "max |Δ| \(fmt(worstDFT))")

    // 1-D Wigner against direct sums, including M < N where rule 1 (|m| ≤ M/2 − 1) binds.
    let zt = Phase.Signal(
      re: (0..<40).map { _ in rng.uniform() - 0.5 }, im: (0..<40).map { _ in rng.uniform() - 0.5 }, step: 0.37e-3, origin: 0.0123)
    let zs = Phase.Signal(
      re: (0..<30).map { _ in rng.uniform() - 0.5 }, im: (0..<30).map { _ in rng.uniform() - 0.5 }, step: 0.21, origin: -1.3,
      domain: .space)
    let cases: [(String, Phase.Signal, Phase.WignerOptions, Int, Bool)] = [
      ("time M = 64 ≥ N, positive band", zt, Phase.WignerOptions(bins: 64), 64, false),
      ("time M = 16 < N = 40 (lags capped at 7), positive band", zt, Phase.WignerOptions(bins: 16), 16, false),
      ("time M = 40, centred band", zt, Phase.WignerOptions(bins: 40, band: .centered), 40, true),
      ("space M = 12 < N = 30 (fallback DFT, lags capped at 5), centred", zs, Phase.WignerOptions(bins: 12), 12, true),
      ("space M = 40, positive band", zs, Phase.WignerOptions(bins: 40, band: .positive), 40, false),
    ]
    for (name, z, opts, m, centred) in cases {
      let w = Phase.wigner(z, options: opts)
      let cols = expectedColumns(domain: z.domain, step: z.step, bins: m, centred: centred)
      let ref = directWigner(z, rows: Array(0..<z.count), columns: cols, lagCap: m / 2 - 1)
      let refMax = ref.reduce(0) { max($0, abs($1)) }
      let e = maxDiff(w.values, ref, scale: refMax)
      let eAxis = maxDiff(w.columnAxis.values, cols, scale: abs(cols[1] - cols[0]))
      log.check(
        "direct-sum Wigner, \(name)", e <= 1e-12 && eAxis <= 1e-9 && w.columns == m,
        "max rel |Δ| \(fmt(e)), axis \(fmt(eAxis)) bins")
    }
    // Pseudo-Wigner (Hann lag 9) and smoothed (Hann time window ±3, weights derived here).
    let hann9: (Int) -> Double = { 0.5 * (1 + cos(Double.pi * Double($0) / 10)) }
    let colsP = expectedColumns(domain: .time, step: zt.step, bins: 32, centred: false)
    let pRef = directWigner(zt, rows: Array(0..<40), columns: colsP, lagCap: 9, h: hann9)
    let pw = Phase.wigner(zt, options: Phase.WignerOptions(bins: 32, lag: .hann(halfWidth: 9)))
    let ePW = maxDiff(pw.values, pRef, scale: pRef.reduce(0) { max($0, abs($1)) })
    let g = (-3...3).map { 0.5 * (1 + cos(Double.pi * Double($0) / 4)) }
    let gSum = g.reduce(0, +)
    var sRef = [Double](repeating: 0, count: 40 * 32)
    for n in 0..<40 {
      for (j, p) in (-3...3).enumerated() where n - p >= 0 && n - p < 40 {
        for c in 0..<32 { sRef[n * 32 + c] += g[j] / gSum * pRef[(n - p) * 32 + c] }
      }
    }
    let sw = Phase.wigner(zt, options: Phase.WignerOptions(bins: 32, lag: .hann(halfWidth: 9), smoothing: .hann(halfWidth: 3)))
    let eSW = maxDiff(sw.values, sRef, scale: sRef.reduce(0) { max($0, abs($1)) })
    log.check(
      "pseudo-Wigner (Hann lag 9) and smoothed pseudo-Wigner (Σg = 1, Hann ±3) vs direct sums", ePW <= 1e-12 && eSW <= 1e-12,
      "max rel |Δ| \(fmt(ePW)) (pseudo), \(fmt(eSW)) (smoothed)")
    // Smoothing keeps the energy for a record that stays inside: P = Σ|z|²Δt.
    let inside = packet(count: 200, step: 2e-3, center: 0.2, sigma: 0.02, carrier: 80)
    let sp = Phase.wigner(inside, options: Phase.WignerOptions(bins: 128, lag: .hann(halfWidth: 40), smoothing: .hann(halfWidth: 6)))
    let ePsm = abs(sp.total - inside.energy()) / inside.energy()
    log.check("smoothed pseudo-Wigner total = record energy (normalized time window)", ePsm < 1e-12, "rel error \(fmt(ePsm))")

    // Spectrogram with a non-unit step: direct STFT and total = energy (Δt Σw² = 1).
    let fs = 8000.0
    let chirp = Phase.Signal.analytic(
      real: (0..<300).map { j -> Double in
        let t = Double(j) / fs
        return cos(2 * Double.pi * (500 * t + 0.5 * 6.6e4 * t * t)) * exp(-pow((t - 0.01875) / 0.004, 2))
      }, step: 1 / fs)
    let sg = Phase.spectrogram(chirp, window: .hann(length: 31), bins: 64)
    let w31 = (0..<31).map { 0.5 * (1 + cos(2 * Double.pi * (Double($0) - 15) / 32)) }
    let wNorm = 1 / (w31.reduce(0) { $0 + $1 * $1 } / fs).squareRoot()
    let colsS = expectedColumns(domain: .time, step: 1 / fs, bins: 64, centred: false)
    var eSG = 0.0
    for n in [20, 150, 290] {
      for (c, v) in colsS.enumerated() {
        var sr = 0.0
        var si = 0.0
        for j in 0..<31 {
          let p = j - 15
          guard n + p >= 0, n + p < 300 else { continue }
          let ph = 2 * Double.pi * v * Double(p) / fs
          let a = chirp.re[n + p] * w31[j] * wNorm
          let b = chirp.im[n + p] * w31[j] * wNorm
          sr += a * cos(ph) - b * sin(ph)
          si += a * sin(ph) + b * cos(ph)
        }
        let s = (sr * sr + si * si) / (fs * fs)
        eSG = max(eSG, abs(sg.value(row: n, column: c) - s) / sg.maxValue)
      }
    }
    let eSGt = abs(sg.total - chirp.energy()) / chirp.energy()
    log.check(
      "spectrogram (fs = 8 kHz) vs direct STFT, total = record energy", eSG < 1e-12 && eSGt < 1e-5,
      "max rel |Δ| \(fmt(eSG)), total rel error \(fmt(eSGt))")

    // Φ against direct sums: exact grid (keepFull, k band positive, ν band centred) and M < N
    // (rule-1 caps |m_x| ≤ 2, |m_t| ≤ 3).
    let nx = 10
    let nt = 9
    let field = Phase.Field(
      re: (0..<(nx * nt)).map { _ in rng.uniform() - 0.5 }, im: (0..<(nx * nt)).map { _ in rng.uniform() - 0.5 },
      x: Phase.Axis(start: -1, step: 0.3, count: nx), t: Phase.Axis(start: 0.5, step: 0.05, count: nt))
    for (name, opts, mx, mt, kc, nc) in [
      ("exact (M 16 × 16), k positive, ν centred", Phase.SpacetimeOptions(kBins: 16, nuBins: 16, kBand: .positive, nuBand: .centered, keepFull: true), 16, 16, false, true),
      ("M < N (6 × 8: lags capped at 2 × 3), k centred, ν positive", Phase.SpacetimeOptions(kBins: 6, nuBins: 8, keepFull: true), 6, 8, true, false),
    ] {
      let w = Phase.spacetimeWigner(field, options: opts)
      let kv = expectedColumns(domain: .space, step: 0.3, bins: mx, centred: kc)
      let nv = expectedColumns(domain: .time, step: 0.05, bins: mt, centred: nc)
      var e = 0.0
      var scale = 0.0
      var ePoint = 0.0
      for (ix, it) in [(0, 0), (4, 4), (9, 2), (5, 8)] {
        let ref = directPhi(field, ix: ix, it: it, k: kv, nu: nv, capX: mx / 2 - 1, capT: mt / 2 - 1)
        let pt = Phase.spacetimeWignerPoint(field, ix: ix, it: it, options: opts)
        scale = max(scale, ref.reduce(0) { max($0, abs($1)) })
        for ck in 0..<mx {
          for cn in 0..<mt {
            e = max(e, abs(Double(w.value(ix: ix, it: it, ck: ck, cnu: cn)!) - ref[ck * mt + cn]))
            ePoint = max(ePoint, abs(pt.re[ck * mt + cn] - ref[ck * mt + cn]))
          }
        }
      }
      log.check(
        "direct-sum Φ at 4 points, \(name)", e <= 1e-6 * scale && ePoint <= 1e-12 * scale,
        "fast path (Float) \(fmt(e / scale)), reference point \(fmt(ePoint / scale))")
    }
    // Φ marginals computed here (no MarginalReport): M1 = |ψ|², M2 = |ψ̃|² + 3 partners, P.
    let w = Phase.spacetimeWigner(field)
    let inten = field.intensity()
    let e1 = maxDiff(w.m1, inten, scale: inten.max()!)
    // The report must see a broken identity: corrupt M1, M2 and P one at a time.
    var badM1 = w
    badM1.m1[17] += 1e-6 * inten.max()!
    var badM2 = w
    badM2.m2[40] += 1e-6 * (w.m2.max() ?? 1)
    var badP = w
    badP.total *= 1 + 1e-6
    let rM1 = Phase.marginalReport(badM1, field: field)
    let rM2 = Phase.marginalReport(badM2, field: field)
    let rP = Phase.marginalReport(badP, field: field)
    log.check(
      "marginal report flags a corrupted M1, M2 or P (1e-6) as INCONSISTENT",
      rM1.status == .inconsistent && abs(rM1.m1Error - 1e-6) < 1e-9 && rM2.status == .inconsistent && rM2.m2IdentityError > 5e-7
        && rP.status == .inconsistent && abs(rP.parsevalError - 1e-6) < 1e-9,
      "M1 \(fmt(rM1.m1Error)) \(rM1.status.badge), M2 \(fmt(rM2.m2IdentityError)) \(rM2.status.badge), P \(fmt(rP.parsevalError)) \(rP.status.badge)")
    var m2Ref = [Double](repeating: 0, count: w.nk * w.nnu)
    for ck in 0..<w.nk {
      for cn in 0..<w.nnu {
        for (sk, sn) in [(0.0, 0.0), (Double.pi / 0.3, 0.0), (0.0, 1 / (2 * 0.05)), (Double.pi / 0.3, 1 / (2 * 0.05))] {
          let k = w.kAxis.value(ck) + sk
          let nu = w.nuAxis.value(cn) + sn
          var sr = 0.0
          var si = 0.0
          for ix in 0..<nx {
            for it in 0..<nt {
              let ph = -k * field.xAxis.value(ix) + 2 * Double.pi * nu * field.tAxis.value(it)
              let a = field.re[ix * nt + it]
              let b = field.im[ix * nt + it]
              sr += a * cos(ph) - b * sin(ph)
              si += a * sin(ph) + b * cos(ph)
            }
          }
          m2Ref[ck * w.nnu + cn] += (sr * sr + si * si) * 0.3 * 0.3 * 0.05 * 0.05
        }
      }
    }
    let e2 = maxDiff(w.m2, m2Ref, scale: m2Ref.max()!)
    let energy = inten.reduce(0, +) * 0.3 * 0.05
    let eP = abs(w.total - energy) / energy
    log.check(
      "Φ marginals recomputed here: M1 = |ψ|², M2 = Σ 4 partners |ψ̃|² (direct DTFT), P = Σ|ψ|²ΔxΔt",
      e1 <= 1e-12 && e2 <= 1e-12 && eP <= 1e-12, "M1 \(fmt(e1)), M2 \(fmt(e2)), P \(fmt(eP))")

    // Fresnel against the closed form: a Gaussian beam's Wigner sheared along x by z k/k₀
    // (paraxial) and z k/√(k₀² − k²) (angular spectrum), and the beam centroid moving by
    // z k_c/k₀ toward +x (independent of the engine's own propagator).
    let k0 = 2 * Double.pi
    let sigma2 = 2.0
    let kc = 0.6
    let beam = Phase.Signal(count: 256, step: 0.25, origin: -32, domain: .space) { x in
      let env = exp(-(x + 4) * (x + 4) / (4 * sigma2))
      return SIMD2(env * cos(kc * x), env * sin(kc * x))
    }
    let w0 = Phase.wigner(beam)
    for (z, model) in [(7.0, Phase.FresnelModel.paraxial), (-5, .paraxial), (7, .angularSpectrum)] {
      let sheared = Phase.fresnelShear(w0, distance: z, wavenumber: k0, model: model)
      var cf = [Double](repeating: 0, count: sheared.values.count)
      for r in 0..<sheared.rows {
        for c in 0..<sheared.columns {
          let k = sheared.columnAxis.value(c)
          guard model == .paraxial || abs(k) < k0 else { continue }
          let s = model == .paraxial ? z * k / k0 : z * k / (k0 * k0 - k * k).squareRoot()
          cf[r * sheared.columns + c] = gaussianBeamWigner(x: sheared.rowAxis.value(r) - s, k: k, x0: -4, sigma2: sigma2, kc: kc)
        }
      }
      let e = maxDiff(sheared.values, cf, scale: cf.max()!)
      log.check(
        "Fresnel shear (\(model.rawValue), z = \(Int(z))λ) = closed-form W₀(x − s(k), k) of a Gaussian beam", e < 1e-9,
        "max rel error \(fmt(e))")
    }
    let prop = Phase.fresnelPropagate(beam, distance: 40, wavenumber: k0)
    func centroid(_ s: Phase.Signal) -> Double {
      let i = s.intensity()
      return zip(i, s.axis.values).map(*).reduce(0, +) / i.reduce(0, +)
    }
    let moved = centroid(prop) - centroid(beam)
    log.check(
      "paraxial propagation moves a tilted beam toward +x by z k_c/k₀", abs(moved - 40 * kc / k0) < 1e-9,
      "moved \(fmt(moved, 8)) vs z k_c/k₀ = \(fmt(40 * kc / k0, 8))")

    // Apertures: a continuous aperture steered +20° peaks at +20°; the far field at angles
    // between columns equals RF's normalizedAF² (an 8-element array steered 20°).
    let cont = Phase.Aperture.continuous(width: 6, illumination: .cosine, steerFromBroadsideDeg: 20)
    let angles = stride(from: -60.0, through: 60.0, by: 0.25).map { $0 }
    let ffc = cont.farField(from: cont.wigner(), anglesDeg: angles)
    let peakAngle = ffc.max { $0.power < $1.power }!.thetaDeg
    log.check("continuous aperture steered +20° radiates toward +20°", abs(peakAngle - 20) <= 0.5, "peak at \(fmt(peakAngle, 4))°")
    let arr = Phase.Aperture.uniformArray(elements: 8, spacing: 0.5, steerFromBroadsideDeg: 20)
    let ffa = arr.farField(from: arr.wigner(), anglesDeg: angles.map { $0 + 0.123 })
    let beta = RF.Arrays.steeringPhase(spacing: 0.5, steerTheta: 70 * Double.pi / 180)
    var eAF = 0.0
    for p in ffa {
      let af = RF.Arrays.normalizedAF(theta: (90 - p.thetaDeg) * Double.pi / 180, elements: 8, spacing: 0.5, beta: beta)
      eAF = max(eAF, abs(p.power - af * af))
    }
    log.check(
      "array far field between columns (481 angles) = RF.Arrays.normalizedAF², peak 1 off-column", eAF < 1e-12,
      "max |Δ| \(fmt(eAF))")
    return log.checks
  }
}

/// SplitMix64 for reproducible test signals.
nonisolated struct SplitMix: Sendable {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

#if !SPECTRA_HARNESS
  /// XCTest runner for the oracle suite: one test per group, one failure per failing check.
  final class PhaseTests: XCTestCase {
    private func assertOracles(_ checks: [PhaseCheck], file: StaticString = #filePath, line: UInt = #line) {
      XCTAssertFalse(checks.isEmpty, "no checks ran", file: file, line: line)
      for c in checks where !c.passed { XCTFail("\(c.name) — \(c.detail)", file: file, line: line) }
    }

    func testConventionsAndPlaneWaveSigns() { assertOracles(PhaseOracleSuite.conventions()) }
    func testAnalyticSignalAndOversampling() { assertOracles(PhaseOracleSuite.analyticSignal()) }
    func testTemporalWignerMarginals() { assertOracles(PhaseOracleSuite.temporalMarginals()) }
    func testSpatialWignerMarginals() { assertOracles(PhaseOracleSuite.spatialMarginals()) }
    func testHudsonPositivityAndCrossTerms() { assertOracles(PhaseOracleSuite.hudsonAndCrossTerms()) }
    func testLinearChirpConcentration() { assertOracles(PhaseOracleSuite.chirpConcentration()) }
    func testMoyalIdentity() { assertOracles(PhaseOracleSuite.moyal()) }
    func testPseudoSmoothedAndSpectrogram() { assertOracles(PhaseOracleSuite.pseudoSmoothedSpectrogram()) }
    func testApertureFarFieldAndFresnelShear() { assertOracles(PhaseOracleSuite.apertureAndFresnel()) }
    func testSpacetimeWigner() { assertOracles(PhaseOracleSuite.spacetime()) }
    func testPacketsClosedFormsAndDispersion() { assertOracles(PhaseOracleSuite.packetsAndDispersion()) }
    func testTimingBudgets() { assertOracles(PhaseOracleSuite.timing()) }
    func testRobustnessAtTheEdges() { assertOracles(PhaseOracleSuite.robustness()) }
    func testIndependentReferences() { assertOracles(PhaseOracleSuite.independentReferences()) }

    /// Every group in the suite has a test method above.
    func testSuiteIsFullyWired() { XCTAssertEqual(PhaseOracleSuite.groups.count, 14) }
  }
#endif
