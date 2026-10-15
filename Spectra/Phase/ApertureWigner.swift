import Foundation

// Spatial Wigner W(x, k) of apertures, the far field as its k marginal, and Fresnel shear.
// Convention (C) in space: Ψ(k) = ∫ψ(x) e^{−ikx} dx, so a current e^{+i k sinθ₀ x} radiates toward
// +θ₀ (θ from broadside, toward +x) and its far-field power pattern is |Ψ(k sinθ)|² — the k
// marginal ∫W dx of the aperture's spatial Wigner (wigner-spacetime.md rule 6).

nonisolated extension Phase {
  /// A sampled aperture current along x (domain `.space`) with the free-space wavelength in the
  /// same length unit (metres, or wavelengths with `wavelength = 1`).
  struct Aperture: Sendable, Hashable {
    var current: Signal
    var wavelength: Double
    /// Element centres for arrays (empty for continuous apertures).
    var elementPositions: [Double]
    /// Element spacing in wavelengths (arrays) or nil.
    var spacingWavelengths: Double?

    var wavenumber: Double { 2 * Double.pi / wavelength }

    enum Illumination: Sendable, Hashable, Codable {
      case uniform
      case cosine
      /// Gaussian taper reaching `edgeTaperDB` (amplitude, dB below centre) at the rim.
      case gaussian(edgeTaperDB: Double)

      func amplitude(_ u: Double) -> Double {
        switch self {
        case .uniform: return 1
        case .cosine: return cos(Double.pi * u / 2)
        case .gaussian(let t):
          let a = max(0, t) * log(10.0) / 20
          return exp(-a * u * u)
        }
      }
    }

    /// N point elements spaced `spacing` wavelengths apart (centred on x = 0), excited with
    /// weights wₙ·e^{+i k sinθ₀ xₙ} (steered to θ₀ from broadside). Sampled on a grid with
    /// `samplesPerElement` (even, ≥ 2) points per spacing, zeros between elements, and
    /// `guardElements` empty spacings on each side (room for the Fresnel shear).
    ///
    /// The element array's spectrum repeats every 2π/d, so on this grid the half-lag Wigner's
    /// k window holds whole grating periods and its k marginal is exactly 2|AF(k)|² (the two
    /// identical replicas fold together); the normalized far field is exactly the array factor.
    static func uniformArray(
      elements n: Int, spacing d: Double, steerFromBroadsideDeg theta0: Double = 0, wavelength: Double = 1,
      samplesPerElement s: Int = 2, weights: [Double]? = nil, guardElements: Int? = nil
    ) -> Aperture {
      // Knob values that are not finite (or a non-positive spacing/wavelength) fall back to the
      // defaults instead of trapping in an Int conversion or producing a zero grid step.
      let wavelength = wavelength.isFinite && wavelength > 0 ? wavelength : 1
      let d = d.isFinite && d > 0 ? d : 0.5
      let theta0 = theta0.isFinite ? theta0 : 0
      let ne = min(max(1, n), 4096)
      let sClamped = min(max(2, s), 64)  // clamp before rounding up to even: s = Int.max must not overflow
      let spe = sClamped + (sClamped & 1)
      let guardCount = min(max(0, guardElements ?? max(2, ne / 2)), 4096)
      let pitch = d * wavelength
      let dx = pitch / Double(spe)
      let count = (ne - 1) * spe + 1 + 2 * guardCount * spe
      let k = 2 * Double.pi / wavelength
      let kx0 = k * sin(theta0 * Double.pi / 180)
      var re = [Double](repeating: 0, count: count)
      var im = re
      var positions: [Double] = []
      let x0 = -(Double(ne - 1) / 2 + Double(guardCount)) * pitch
      for e in 0..<ne {
        let idx = guardCount * spe + e * spe
        let x = x0 + Double(idx) * dx
        positions.append(x)
        let w = weights.flatMap { e < $0.count ? $0[e] : nil } ?? 1
        re[idx] = w * cos(kx0 * x) / dx
        im[idx] = w * sin(kx0 * x) / dx
      }
      return Aperture(
        current: Signal(re: re, im: im, step: dx, origin: x0, domain: .space), wavelength: wavelength,
        elementPositions: positions, spacingWavelengths: d)
    }

    /// A continuous aperture of width D wavelengths (horn, dish cut, slot), centred on x = 0,
    /// sampled `samplesPerWavelength` (≥ 4) per λ so the visible region |kₓ| ≤ k lies inside the
    /// centred band, with `guardFraction`·D of zeros on each side.
    static func continuous(
      width: Double, illumination: Illumination = .uniform, steerFromBroadsideDeg theta0: Double = 0,
      wavelength: Double = 1, samplesPerWavelength: Int = 8, guardFraction: Double = 0.5
    ) -> Aperture {
      // Non-finite or non-positive knob values fall back to defaults (no trap in Int(…)); the
      // record is capped at 2¹⁸ samples so a huge dish cannot allocate without bound.
      let wavelength = wavelength.isFinite && wavelength > 0 ? wavelength : 1
      let width = width.isFinite && width > 0 ? width : 1
      let guardFraction = guardFraction.isFinite && guardFraction > 0 ? guardFraction : 0
      let theta0 = theta0.isFinite ? theta0 : 0
      let spl = min(max(4, samplesPerWavelength), 1024)
      let dx = wavelength / Double(spl)
      let half = Int(min(max(1, (width * wavelength / 2 / dx).rounded()), 65_536))
      let guardCount = Int(min(max(4, (guardFraction * width * wavelength / dx).rounded()), 65_536))
      let count = 2 * (half + guardCount) + 1
      let k = 2 * Double.pi / wavelength
      let kx0 = k * sin(theta0 * Double.pi / 180)
      let origin = -Double(half + guardCount) * dx
      var re = [Double](repeating: 0, count: count)
      var im = re
      for j in 0..<count {
        let x = origin + Double(j) * dx
        let u = x / (Double(half) * dx)
        guard abs(u) <= 1 + 1e-12 else { continue }
        let a = illumination.amplitude(u)
        re[j] = a * cos(kx0 * x)
        im[j] = a * sin(kx0 * x)
      }
      return Aperture(
        current: Signal(re: re, im: im, step: dx, origin: origin, domain: .space), wavelength: wavelength,
        elementPositions: [], spacingWavelengths: nil)
    }

    /// Spatial Wigner W(x, kₓ) of the current (exact: full lag over the record), centred band.
    func wigner(bins: Int? = nil) -> Plane {
      Phase.wigner(
        current, options: WignerOptions(bins: bins ?? DFT.goodSize(atLeast: current.count), lag: .full, band: .centered))
    }

    /// |Ψ(kₓ)|² of the current, computed directly (the far-field power, unnormalized).
    func farFieldPower(kx: Double) -> Double {
      var sr = 0.0
      var si = 0.0
      for j in 0..<current.count where current.re[j] != 0 || current.im[j] != 0 {
        let x = current.origin + Double(j) * current.step
        let c = cos(kx * x)
        let s = -sin(kx * x)
        sr += current.re[j] * c - current.im[j] * s
        si += current.re[j] * s + current.im[j] * c
      }
      let h = current.step
      return (sr * sr + si * si) * h * h
    }

    /// Normalized far-field power pattern read from a Wigner's k marginal at angles θ (degrees
    /// from broadside): kₓ = k sinθ, wrapped into the plane's k period (exact for element
    /// arrays, whose spectrum repeats every 2π/d).
    ///
    /// Between columns the marginal is evaluated exactly, not interpolated linearly: with half-lags
    /// |m| ≤ M/2 − 1 the k marginal Σₓ W Δx is a trigonometric polynomial of degree M/2 − 1 in
    /// kₓ (period π/Δx), so its M column samples determine it everywhere (`MarginalCurve`).
    /// Powers are normalized to the curve's true maximum (not the largest column), so the beam
    /// peak reads 1 and the pattern equals `RF.Arrays.normalizedAF²` at every angle (oracle).
    /// Non-finite angles give power 0.
    func farField(from plane: Plane, anglesDeg: [Double]) -> [FarFieldPoint] {
      let curve = MarginalCurve(plane: plane)
      let peak = curve.peak
      let k = wavenumber
      return anglesDeg.map { deg in
        let kx = k * sin(deg * Double.pi / 180)
        guard kx.isFinite, peak > 0 else { return FarFieldPoint(thetaDeg: deg, kx: kx, power: 0) }
        return FarFieldPoint(thetaDeg: deg, kx: kx, power: max(0, curve.value(atColumnValue: kx)) / peak)
      }
    }

    /// The visible columns (|kₓ| ≤ k) of a Wigner's k marginal as a normalized pattern (exact
    /// marginal values at the columns, normalized to the curve's true maximum).
    func farField(from plane: Plane) -> [FarFieldPoint] {
      let curve = MarginalCurve(plane: plane)
      let peak = curve.peak
      let k = wavenumber
      var out: [FarFieldPoint] = []
      for c in 0..<plane.columns {
        let kx = plane.columnAxis.value(c)
        guard abs(kx) <= k else { continue }
        out.append(
          FarFieldPoint(thetaDeg: asin(kx / k) * 180 / Double.pi, kx: kx, power: peak > 0 ? max(0, curve.samples[c]) / peak : 0))
      }
      return out
    }
  }

  /// The column marginal of a Wigner plane (Σ_rows W · row measure, ≈ |Z(ν)|² or |Ψ(k)|²) as a
  /// continuous function of the column value. With half-lags |m| ≤ M/2 − 1 the marginal is a
  /// trigonometric polynomial of degree M/2 − 1 over one Wigner period, so the M column samples
  /// determine it exactly (DFT interpolation); for binned or smoothed planes the same
  /// interpolation is a band-limited fit through the columns.
  struct MarginalCurve: Sendable, Hashable {
    /// The column marginal (`plane.columnMarginal()`).
    var samples: [Double]
    var axis: Axis
    /// Fourier coefficients d_m (m = 0 … M/2) of the curve in column units u: value(u) =
    /// d₀ + 2 Σ Re(d_m e^{2πi u m/M}) + d_{M/2} cos(πu).
    var coefficientsRe: [Double]
    var coefficientsIm: [Double]
    /// True maximum of the curve (over the whole period, refined between columns).
    var peak: Double

    init(plane: Plane) {
      self.init(samples: plane.columnMarginal(), axis: plane.columnAxis)
    }

    init(samples: [Double], axis: Axis) {
      let m = samples.count
      self.samples = samples
      self.axis = axis
      guard m > 0, samples.allSatisfy(\.isFinite) else {
        coefficientsRe = []
        coefficientsIm = []
        peak = samples.filter(\.isFinite).max() ?? 0
        return
      }
      let (fr, fi) = DFT(count: m).transform(.negative, re: samples, im: [Double](repeating: 0, count: m))
      let inv = 1 / Double(m)
      coefficientsRe = (0...(m / 2)).map { fr[$0] * inv }
      coefficientsIm = (0...(m / 2)).map { fi[$0] * inv }
      // Peak: best of the columns and a ≥ 8× oversampled scan (zero-padded inverse DFT of the
      // coefficients), then golden-section refinement on the exact curve.
      var bestU = 0.0
      var best = -Double.infinity
      for c in 0..<m where samples[c] > best {
        best = samples[c]
        bestU = Double(c)
      }
      peak = best
      let l = DFT.goodSize(atLeast: 8 * m)
      var dr = [Double](repeating: 0, count: l)
      var di = dr
      dr[0] = coefficientsRe[0]
      let top = m % 2 == 0 ? m / 2 - 1 : m / 2
      if top >= 1 {
        for j in 1...top {
          dr[j] = coefficientsRe[j]
          di[j] = coefficientsIm[j]
          dr[l - j] = coefficientsRe[j]
          di[l - j] = -coefficientsIm[j]
        }
      }
      if m % 2 == 0 {
        dr[m / 2] += coefficientsRe[m / 2] / 2
        dr[l - m / 2] += coefficientsRe[m / 2] / 2
      }
      let (fine, _) = DFT(count: l).transform(.positive, re: dr, im: di)
      let du = Double(m) / Double(l)
      for j in 0..<l where fine[j] > best {
        best = fine[j]
        bestU = Double(j) * du
      }
      var a = bestU - du
      var b = bestU + du
      let g = (5.0.squareRoot() - 1) / 2
      var x1 = b - g * (b - a)
      var x2 = a + g * (b - a)
      var f1 = value(atColumn: x1)
      var f2 = value(atColumn: x2)
      for _ in 0..<40 {
        if f1 > f2 {
          b = x2
          x2 = x1
          f2 = f1
          x1 = b - g * (b - a)
          f1 = value(atColumn: x1)
        } else {
          a = x1
          x1 = x2
          f1 = f2
          x2 = a + g * (b - a)
          f2 = value(atColumn: x2)
        }
      }
      peak = max(best, f1, f2)
    }

    /// The curve at fractional column u (periodic in M columns).
    func value(atColumn u: Double) -> Double {
      let m = samples.count
      guard m > 0, u.isFinite else { return 0 }
      guard !coefficientsRe.isEmpty else {
        let i = Int(min(max(0, u.rounded()), Double(m - 1)))
        return samples[i].isFinite ? samples[i] : 0
      }
      var s = coefficientsRe[0]
      let w = 2 * Double.pi * u / Double(m)
      let top = m % 2 == 0 ? m / 2 - 1 : m / 2
      if top >= 1 {
        for j in 1...top {
          let ph = w * Double(j)
          s += 2 * (coefficientsRe[j] * cos(ph) - coefficientsIm[j] * sin(ph))
        }
      }
      if m % 2 == 0 { s += coefficientsRe[m / 2] * cos(Double.pi * u) }
      return s
    }

    /// The curve at a column value (ν in Hz or k in rad/m), wrapped into the Wigner period.
    func value(atColumnValue v: Double) -> Double {
      guard axis.step != 0, v.isFinite else { return 0 }
      return value(atColumn: (v - axis.start) / axis.step)
    }
  }

  struct FarFieldPoint: Sendable, Hashable {
    /// Degrees from broadside (toward +x).
    var thetaDeg: Double
    var kx: Double
    /// Normalized to the pattern peak (0…1).
    var power: Double
  }

  /// Propagation model for the shear and for direct propagation.
  enum FresnelModel: String, Sendable, Hashable, Codable {
    /// Paraxial (Fresnel): transfer e^{−i z k²/(2k₀)}; the Wigner shears exactly, x → x + z k/k₀.
    case paraxial
    /// Angular spectrum: transfer e^{i(√(k₀² − k²) − k₀) z}; the shear z·k/√(k₀² − k²) is the
    /// ray (geometric) picture, exact in the far field; evanescent columns are dropped.
    case angularSpectrum
  }

  /// How `fresnelShear` resamples each k column.
  enum ShearInterpolation: String, Sendable, Hashable, Codable {
    /// Band-limited shift (FFT phase ramp) on the input grid: exact for smooth columns.
    case fourier
    /// Catmull–Rom cubic; used automatically when the output axis differs from the input.
    case cubic
  }

  /// Fresnel shear of a spatial Wigner (rule 6): W_z(x, k) = W₀(x − s(k), k) with
  /// s = z k/k₀ (paraxial) or z k/√(k₀² − k²) (angular spectrum). Each k column is shifted
  /// (band-limited Fourier shift on the input rows, or cubic interpolation onto `rowAxis`);
  /// content shifted out of the record is lost (0). Use a wider output axis (cubic), or rescale
  /// x by z for the far field, when the beam leaves the window.
  static func fresnelShear(
    _ plane: Plane, distance z: Double, wavenumber k0: Double, model: FresnelModel = .paraxial, rowAxis: Axis? = nil,
    interpolation: ShearInterpolation = .fourier
  ) -> Plane {
    // A non-finite distance or a wavenumber that is not a positive number has no shear: the
    // plane comes back unsheared (relabelled), never NaN or blank.
    let z = z.isFinite ? z : 0
    let k0 = k0.isFinite && k0 > 0 ? k0 : 0
    let out = rowAxis ?? plane.rowAxis
    let useFourier = interpolation == .fourier && out == plane.rowAxis && plane.rows > 1
    var values = [Double](repeating: 0, count: out.count * plane.columns)
    let src = plane.rowAxis
    let r = plane.rows
    let p = DFT.goodSize(atLeast: 2 * max(r, 1))
    let dft = useFourier ? DFT(count: p) : nil
    var bufR = [Double](repeating: 0, count: useFourier ? p : 0)
    var bufI = bufR
    let active = z != 0 && k0 > 0
    for c in 0..<plane.columns {
      let k = plane.columnAxis.value(c)
      let shift: Double
      switch model {
      case _ where !active:
        shift = 0
      case .paraxial:
        shift = z * k / k0
      case .angularSpectrum:
        guard abs(k) < k0 else { continue }
        shift = z * k / (k0 * k0 - k * k).squareRoot()
      }
      if let dft {
        let s = shift / src.step
        guard abs(s) < Double(r) else { continue }
        for j in 0..<p {
          bufR[j] = j < r ? plane.values[j * plane.columns + c] : 0
          bufI[j] = 0
        }
        var (fr, fi) = dft.transform(.negative, re: bufR, im: bufI)
        for q in 0..<p {
          let sq = q < (p + 1) / 2 ? q : q - p
          if p % 2 == 0 && q == p / 2 {
            let h = cos(Double.pi * s)
            fr[q] *= h
            fi[q] *= h
            continue
          }
          let ph = -2 * Double.pi * Double(sq) * s / Double(p)
          let cr = cos(ph)
          let ci = sin(ph)
          let a = fr[q]
          let b = fi[q]
          fr[q] = a * cr - b * ci
          fi[q] = a * ci + b * cr
        }
        let (or, _) = dft.transform(.positive, re: fr, im: fi)
        let inv = 1 / Double(p)
        for j in 0..<r { values[j * plane.columns + c] = or[j] * inv }
      } else {
        for j in 0..<out.count {
          let f = src.fractionalIndex(out.value(j) - shift)
          values[j * plane.columns + c] = cubicSample(plane, column: c, at: f)
        }
      }
    }
    var result = plane
    result.kind = .fresnelSheared
    result.rowAxis = out
    result.values = values
    result.rowMeasure = out.step
    result.rowIndices = []
    result.coversRecord = false
    return result
  }

  /// Catmull–Rom sample of one column at fractional row f (0 outside the rows).
  static func cubicSample(_ plane: Plane, column c: Int, at f: Double) -> Double {
    guard f.isFinite, f > -1, f < Double(plane.rows) else { return 0 }
    let i = Int(floor(f))
    let t = f - Double(i)
    func v(_ r: Int) -> Double { r >= 0 && r < plane.rows ? plane.values[r * plane.columns + c] : 0 }
    let p0 = v(i - 1)
    let p1 = v(i)
    let p2 = v(i + 1)
    let p3 = v(i + 2)
    let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
    let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
    let cc = -0.5 * p0 + 0.5 * p2
    return ((a * t + b) * t + cc) * t + p1
  }

  /// Direct propagation of a 1-D field by z (spectral, zero-padded `padding`× so it does not
  /// wrap; the result is cropped back to the input grid). The global e^{ik₀z} is dropped.
  static func fresnelPropagate(
    _ field: Signal, distance z: Double, wavenumber k0: Double, model: FresnelModel = .paraxial, padding: Int = 4
  ) -> Signal {
    let n = field.count
    // Nothing to propagate, or no propagation defined (z not finite, k₀ not a positive number,
    // no usable step): the field comes back unchanged instead of NaN.
    guard n > 0, z.isFinite, z != 0, k0.isFinite, k0 > 0, isUsableStep(field.step) else { return field }
    let p = DFT.goodSize(atLeast: min(max(1, padding), 64) * n)
    var r = [Double](repeating: 0, count: p)
    var i = r
    let offset = (p - n) / 2
    for j in 0..<n {
      r[offset + j] = field.re[j]
      i[offset + j] = field.im[j]
    }
    let dft = DFT(count: p)
    var (fr, fi) = dft.transform(.negative, re: r, im: i)
    let dk = 2 * Double.pi / (Double(p) * field.step)
    for q in 0..<p {
      let s = q < (p + 1) / 2 ? q : q - p
      let k = Double(s) * dk
      let hr: Double
      let hi: Double
      switch model {
      case .paraxial:
        let ph = -z * k * k / (2 * k0)
        hr = cos(ph)
        hi = sin(ph)
      case .angularSpectrum:
        if abs(k) < k0 {
          let ph = ((k0 * k0 - k * k).squareRoot() - k0) * z
          hr = cos(ph)
          hi = sin(ph)
        } else {
          let a = exp(-(k * k - k0 * k0).squareRoot() * abs(z))
          let ph = -k0 * z
          hr = a * cos(ph)
          hi = a * sin(ph)
        }
      }
      let a = fr[q]
      let b = fi[q]
      fr[q] = a * hr - b * hi
      fi[q] = a * hi + b * hr
    }
    let (or, oi) = dft.transform(.positive, re: fr, im: fi)
    let s = 1 / Double(p)
    return Signal(
      re: (0..<n).map { or[offset + $0] * s }, im: (0..<n).map { oi[offset + $0] * s }, step: field.step, origin: field.origin,
      domain: .space)
  }
}
