import Foundation
import simd

nonisolated extension Phase {
  /// A uniformly sampled complex 1-D record z[n] = re[n] + i·im[n] at `origin + n·step`, in time
  /// (step = Δt, s) or in space (step = Δx, m — or any consistent display unit).
  ///
  /// Convention (C): a time signal with positive frequency ν₀ is e^{−2πiν₀t}; a spatial field
  /// with positive wavenumber k₀ is e^{+ik₀x}. Use `analytic(real:…)` for real streams and
  /// `fromIQ(…)` for engineering I + jQ baseband (which uses e^{+j2πft} for +f).
  struct Signal: Sendable, Hashable {
    var re: [Double]
    var im: [Double]
    var step: Double
    var origin: Double
    var domain: Domain

    init(re: [Double], im: [Double], step: Double, origin: Double = 0, domain: Domain = .time) {
      precondition(re.count == im.count, "Phase.Signal: re and im differ in length")
      self.re = re
      self.im = im
      self.step = step
      self.origin = origin
      self.domain = domain
    }

    /// A real record taken as complex with zero imaginary part (not analytic: its Wigner has the
    /// ±ν mirror cross term at ν = 0; use `analytic(real:…)` for that, rule 3).
    init(real: [Double], step: Double, origin: Double = 0, domain: Domain = .time) {
      self.init(re: real, im: [Double](repeating: 0, count: real.count), step: step, origin: origin, domain: domain)
    }

    /// Samples z[n] = f(origin + n·step) of a complex function.
    init(count: Int, step: Double, origin: Double = 0, domain: Domain = .time, _ f: (Double) -> SIMD2<Double>) {
      var r = [Double](repeating: 0, count: max(0, count))
      var i = r
      for n in 0..<max(0, count) {
        let v = f(origin + Double(n) * step)
        r[n] = v.x
        i[n] = v.y
      }
      self.init(re: r, im: i, step: step, origin: origin, domain: domain)
    }

    var count: Int { re.count }
    var axis: Axis { Axis(start: origin, step: step, count: count) }
    /// Sample rate 1/step (Hz for time, samples per metre for space).
    var rate: Double { 1 / step }

    /// |z[n]|².
    func intensity() -> [Double] { (0..<count).map { re[$0] * re[$0] + im[$0] * im[$0] } }
    /// Σ|z|²·step.
    func energy() -> Double { intensity().reduce(0, +) * step }
    func conjugated() -> Signal { Signal(re: re, im: im.map { -$0 }, step: step, origin: origin, domain: domain) }

    /// Non-finite samples replaced by 0 (a sensor glitch must not blank a whole Wigner image).
    func sanitized() -> Signal {
      var s = self
      for n in 0..<count where !(re[n].isFinite && im[n].isFinite) {
        s.re[n] = 0
        s.im[n] = 0
      }
      return s
    }

    /// Samples first ..< first + length (clamped).
    func slice(_ range: Range<Int>) -> Signal {
      let lo = max(0, min(count, range.lowerBound))
      let hi = max(lo, min(count, range.upperBound))
      return Signal(
        re: Array(re[lo..<hi]), im: Array(im[lo..<hi]), step: step, origin: origin + Double(lo) * step, domain: domain)
    }

    static func + (a: Signal, b: Signal) -> Signal {
      precondition(a.count == b.count, "Phase.Signal +: lengths differ")
      return Signal(
        re: zip(a.re, b.re).map(+), im: zip(a.im, b.im).map(+), step: a.step, origin: a.origin, domain: a.domain)
    }

    func scaled(_ a: Double) -> Signal {
      Signal(re: re.map { $0 * a }, im: im.map { $0 * a }, step: step, origin: origin, domain: domain)
    }

    // MARK: Conversions

    /// Engineering baseband I + jQ (positive frequency e^{+j2πft}, as `RF.IQBuffer`) converted to
    /// convention (C) by conjugation, so a tone at +f lands at +ν. The image equals the usual
    /// engineering Wigner–Ville of I + jQ.
    static func fromIQ(i: [Float], q: [Float], sampleRate: Double, origin: Double = 0) -> Signal {
      precondition(i.count == q.count, "fromIQ: I and Q differ in length")
      return Signal(re: i.map(Double.init), im: q.map { -Double($0) }, step: 1 / sampleRate, origin: origin, domain: .time)
    }

    /// Same for (I, Q) pairs, e.g. `FIDSignal.baseband(…)`.
    static func fromIQ(_ samples: [SIMD2<Double>], sampleRate: Double, origin: Double = 0) -> Signal {
      Signal(re: samples.map(\.x), im: samples.map { -$0.y }, step: 1 / sampleRate, origin: origin, domain: .time)
    }

    /// Back to engineering I + jQ (conjugate of convention C).
    func toIQ() -> (i: [Float], q: [Float]) { (re.map { Float($0) }, im.map { Float(-$0) }) }
  }

  /// How the FFT Hilbert transform treats the record ends.
  enum Padding: String, Sendable, Hashable, Codable {
    /// Zero-padded to ≥ 2N (finite-support record; the default).
    case linear
    /// The record is one period of a periodic signal (exact for whole-cycle tones).
    case circular
  }
}

// MARK: - Analytic signal and oversampling

nonisolated extension Phase.Signal {
  /// Analytic signal of a real record (rule 3) via the FFT Hilbert transform, in convention (C):
  /// only positive frequencies (ν > 0 in time, k > 0 in space) survive, doubled; DC and the
  /// Nyquist bin are kept once. Re z = x exactly.
  ///
  /// - time: z = x − i·H[x] (cos 2πν₀t → e^{−2πiν₀t}, which lands at +ν₀);
  /// - space: z = x + i·H[x] (cos k₀x → e^{+ik₀x}, which lands at +k₀).
  static func analytic(
    real x: [Double], step: Double, origin: Double = 0, domain: Phase.Domain = .time, padding: Phase.Padding = .linear
  ) -> Phase.Signal {
    let n = x.count
    guard n > 0 else { return Phase.Signal(re: [], im: [], step: step, origin: origin, domain: domain) }
    let p: Int
    switch padding {
    case .linear: p = Phase.DFT.goodSize(atLeast: 2 * n)
    case .circular: p = n
    }
    var re = [Double](repeating: 0, count: p)
    let im = [Double](repeating: 0, count: p)
    for i in 0..<n { re[i] = x[i].isFinite ? x[i] : 0 }
    let dft = Phase.DFT(count: p)
    var (xr, xi) = dft.transform(.negative, re: re, im: im)
    // Standard one-sided spectrum (bins 1 … ⌈p/2⌉−1 doubled, DC and Nyquist once).
    let half = p / 2
    for q in 1..<p {
      let isNyquist = p % 2 == 0 && q == half
      if isNyquist { continue }
      if q < (p + 1) / 2 {
        xr[q] *= 2
        xi[q] *= 2
      } else {
        xr[q] = 0
        xi[q] = 0
      }
    }
    let (_, zi) = dft.transform(.positive, re: xr, im: xi)
    let s = 1 / Double(p)
    var outRe = [Double](repeating: 0, count: n)
    var outIm = outRe
    // Standard analytic z_s = x + iH[x]; convention (C) time keeps e^{−2πiνt}: z = conj(z_s).
    let imSign: Double = domain == .time ? -1 : 1
    for i in 0..<n {
      outRe[i] = x[i].isFinite ? x[i] : 0  // Re z = x exactly
      outIm[i] = imSign * zi[i] * s
    }
    return Phase.Signal(re: outRe, im: outIm, step: step, origin: origin, domain: domain)
  }

  /// Float convenience for sensor rings and audio blocks.
  static func analytic(
    real x: [Float], sampleRate: Double, origin: Double = 0, padding: Phase.Padding = .linear
  ) -> Phase.Signal {
    analytic(real: x.map(Double.init), step: 1 / sampleRate, origin: origin, domain: .time, padding: padding)
  }

  /// Band-limited 2× interpolation (rule 2) by zero insertion in the DFT: the result has 2N
  /// samples at step/2 and passes exactly through the originals (z′[2n] = z[n]). With `.linear`
  /// padding the record is zero-padded first so the interpolation does not wrap around.
  func oversampled2x(padding: Phase.Padding = .linear) -> Phase.Signal {
    let n = count
    guard n > 0 else { return Phase.Signal(re: [], im: [], step: step / 2, origin: origin, domain: domain) }
    let p: Int
    switch padding {
    case .linear: p = Phase.DFT.goodSize(atLeast: 2 * n)
    case .circular: p = n
    }
    var r = [Double](repeating: 0, count: p)
    var i = r
    // Non-finite samples count as 0 (as in `wigner`): the interpolation would spread one NaN
    // over every output sample.
    for j in 0..<n where re[j].isFinite && im[j].isFinite {
      r[j] = re[j]
      i[j] = im[j]
    }
    let dft = Phase.DFT(count: p)
    let (zr, zi) = dft.transform(.negative, re: r, im: i)
    let p2 = 2 * p
    var ur = [Double](repeating: 0, count: p2)
    var ui = ur
    // Low half to the start, high half (negative frequencies) to the end; the Nyquist bin of an
    // even-length record splits in two so the result stays exactly interpolating.
    let half = p / 2
    for q in 0..<p {
      if p % 2 == 0 && q == half {
        ur[half] = zr[q] / 2
        ui[half] = zi[q] / 2
        ur[p2 - half] = zr[q] / 2
        ui[p2 - half] = zi[q] / 2
      } else if q < (p + 1) / 2 {
        ur[q] = zr[q]
        ui[q] = zi[q]
      } else {
        ur[q + p] = zr[q]
        ui[q + p] = zi[q]
      }
    }
    let big = Phase.DFT(count: p2)
    let (outR, outI) = big.transform(.positive, re: ur, im: ui)
    let s = 1 / Double(p)
    return Phase.Signal(
      re: (0..<(2 * n)).map { outR[$0] * s }, im: (0..<(2 * n)).map { outI[$0] * s }, step: step / 2, origin: origin,
      domain: domain)
  }
}

// MARK: - Spectrum (the M2 reference)

nonisolated extension Phase {
  /// |Z|² of a record on the column grid of a Wigner with `bins` M, in convention (C):
  /// Z(ν) = Δt Σ z[n] e^{+2πiν t_n} (time), Ψ(k) = Δx Σ ψ[n] e^{−ik x_n} (space).
  /// `aliased` adds the partner half a Wigner period away (|Z(ν)|² + |Z(ν + fs/2)|²), which is
  /// exactly what the discrete time marginal M2 returns (rule 2).
  struct Spectrum: Sendable, Hashable {
    var axis: Axis
    var power: [Double]
    var aliased: [Double]
    /// The alias term alone, aliased − power.
    var alias: [Double] { zip(aliased, power).map { $0 - $1 } }
    /// Peak of `power`.
    var peak: Double { power.max() ?? 0 }
  }

  /// Column axis of an M-bin Wigner of a record with `step` in `domain` (ν in Hz or k in rad/m).
  static func columnAxis(domain: Domain, step: Double, bins m: Int, band: Band) -> Axis {
    let d = domain.axisScale(step: step) / Double(2 * m)
    let start = band == .positive ? 0 : -Double(m / 2) * d
    return Axis(start: start, step: d, count: m)
  }

  /// The column measure (dν, or dk/2π) of an M-bin Wigner: 1/(2M·step) in both domains.
  static func columnMeasure(step: Double, bins m: Int) -> Double { 1 / (Double(2 * m) * step) }

  /// Complex Z on the full 2M grid (index g ↔ value g·d, period 2·Wigner period), exact DTFT
  /// samples (records longer than 2M are folded, which is exact on the grid).
  static func transformOnGrid(_ s: Signal, bins m: Int) -> (re: [Double], im: [Double]) {
    guard m > 0 else { return ([], []) }
    let g = 2 * m
    var r = [Double](repeating: 0, count: g)
    var i = r
    for n in 0..<s.count {
      r[n % g] += s.re[n]
      i[n % g] += s.im[n]
    }
    let dft = DFT(count: g)
    var (zr, zi) = dft.transform(s.domain == .time ? .positive : .negative, re: r, im: i)
    // Phase of the record origin: e^{±i·2π·(g·d)·origin} with the domain's sign.
    let d = s.domain.axisScale(step: s.step) / Double(g)
    let sgn = s.domain.exponentSign
    for q in 0..<g {
      let value = Double(q) * d
      let phi = s.domain == .time ? 2 * Double.pi * value * s.origin : value * s.origin
      let c = cos(sgn * phi)
      let sn = sin(sgn * phi)
      let a = zr[q] * s.step
      let b = zi[q] * s.step
      zr[q] = a * c - b * sn
      zi[q] = a * sn + b * c
    }
    return (zr, zi)
  }

  /// |Z|² and its aliased form on the columns of an M-bin Wigner.
  static func spectrum(_ s: Signal, bins requested: Int, band: Band) -> Spectrum {
    // bins ≤ 0 (an empty plane's columns) gives an empty spectrum; huge requests are clamped.
    guard requested > 0 else { return Spectrum(axis: Axis(start: 0, step: 0, count: 0), power: [], aliased: []) }
    let m = min(requested, maxBins)
    let (zr, zi) = transformOnGrid(s.sanitized(), bins: m)
    let g = 2 * m
    var power = [Double](repeating: 0, count: m)
    var aliased = power
    for c in 0..<m {
      let a = band.spectrumIndex(column: c, bins: m)
      let b = (a + m) % g
      let pa = zr[a] * zr[a] + zi[a] * zi[a]
      let pb = zr[b] * zr[b] + zi[b] * zi[b]
      power[c] = pa
      aliased[c] = pa + pb
    }
    return Spectrum(axis: columnAxis(domain: s.domain, step: s.step, bins: m, band: band), power: power, aliased: aliased)
  }

  /// Moyal reference for two records on the same grid: |⟨f, g⟩|² = |Σ f* g · step|² and its alias
  /// |Σ (−1)ⁿ f* g · step|². The discrete Moyal identity is
  /// Σ W_f W_g · step · column measure = inner + alias (full lag, every row, same M ≥ N).
  static func moyalReference(_ f: Signal, _ g: Signal) -> (inner: Double, alias: Double) {
    precondition(f.count == g.count, "moyalReference: lengths differ")
    var sr = 0.0
    var si = 0.0
    var ar = 0.0
    var ai = 0.0
    for n in 0..<f.count {
      let pr = f.re[n] * g.re[n] + f.im[n] * g.im[n]
      let pi = f.re[n] * g.im[n] - f.im[n] * g.re[n]
      sr += pr
      si += pi
      if n % 2 == 0 {
        ar += pr
        ai += pi
      } else {
        ar -= pr
        ai -= pi
      }
    }
    let h2 = f.step * f.step
    return ((sr * sr + si * si) * h2, (ar * ar + ai * ai) * h2)
  }
}
