import Foundation
import simd

nonisolated extension RF {
  /// A one-dimensional source distribution: what radiates, sampled along one local axis, in
  /// wavelengths. Its Fourier transform over the direction cosine u along that axis,
  /// F(u) = Σₙ aₙ·e^{j2π·xₙ·u}·w (w = Δx for a continuous aperture, 1 for discrete elements),
  /// is the factor of the pattern in the principal plane that contains the axis. That is the
  /// k_x marginal of the spatial Wigner distribution W(x, k_x) with k_x = k·u, the "Aperture phase
  /// space" view of SPEC-features §3c. A phased array's steering is the linear phase of aₙ, which
  /// shifts W along k_x.
  struct ApertureDistribution: Sendable {
    /// Sample positions xₙ (λ), ascending and uniformly spaced, centred on the antenna.
    let positions: [Double]
    /// Grid spacing Δx (λ).
    let spacing: Double
    /// Complex source amplitude aₙ at each position (Float split complex, like signal buffers).
    let samples: IQBuffer
    /// Local axis the positions run along (x for apertures and arrays, z for wires and the Yagi
    /// boom, y for an H-plane cut).
    let axis: SIMD3<Double>
    /// True when the sources are discrete elements (array, Yagi, the patch's two slots): each
    /// sample is one point source, not a slice of a continuous aperture.
    let isDiscrete: Bool
    /// What is sampled, in plain words ("TE₁₀ cosine across A", "sinusoidal current").
    let description: String

    /// F(u) at direction cosine u along `axis` (u = sinθ from broadside for apertures and arrays,
    /// cosθ from the wire for dipoles and the Yagi boom).
    func factor(directionCosine u: Double) -> RF.Complex {
      let w = isDiscrete ? 1 : spacing
      var re = 0.0
      var im = 0.0
      for n in positions.indices {
        let a = Double(samples.i[n])
        let b = Double(samples.q[n])
        let phase = 2 * Double.pi * positions[n] * u
        let c = cos(phase)
        let s = sin(phase)
        re += a * c - b * s
        im += a * s + b * c
      }
      return RF.Complex(re * w, im * w)
    }
  }
}

nonisolated extension RF.AntennaModel {
  /// The source distribution behind the pattern along the E-plane or H-plane axis, sampled every
  /// `spacing` λ (1/32 by default; discrete elements are sampled at their own positions):
  ///
  /// - phased array: N elements at spacing d with the steering phase β·n (x for E, y for H);
  /// - horn: uniform across B (E, x) or the TE₁₀ cosine cos(πy/A) across A (H, y);
  /// - dish: the uniform disc projected on the axis, √(R² − x²), whose transform is the Airy
  ///   factor 2J₁(πDu)/(πDu);
  /// - patch: the two radiating slots at ±L_e/2 (E, x) or the uniform slot width W (H, y);
  /// - dipole, monopole (with its image) and short dipole: the current I(z) on the wire, E only;
  /// - Yagi: the N elements along the boom with the Hansen–Woodyard phase, E only.
  ///
  /// Nil for the helix, small loop and PIFA (no line source behind their model patterns) and for
  /// the H-plane of wire antennas (a point source there).
  func apertureDistribution(plane: RF.PatternPlane = .e, spacing requested: Double = 1.0 / 32) -> RF.ApertureDistribution? {
    let p = parameters
    let step = requested.isFinite ? min(max(requested, 1e-3), 0.5) : 1.0 / 32
    let x = SIMD3<Double>(1, 0, 0)
    let y = SIMD3<Double>(0, 1, 0)
    let z = SIMD3<Double>(0, 0, 1)

    /// Midpoint samples of a continuous source over [−a, a].
    func continuous(halfLength a: Double, axis: SIMD3<Double>, _ text: String, _ amplitude: (Double) -> Double) -> RF.ApertureDistribution {
      let m = max(2, Int((2 * a / step).rounded(.up)))
      let dx = 2 * a / Double(m)
      let xs = (0..<m).map { -a + (Double($0) + 0.5) * dx }
      return RF.ApertureDistribution(
        positions: xs, spacing: dx, samples: RF.IQBuffer(real: xs.map { Float(amplitude($0)) }), axis: axis, isDiscrete: false, description: text)
    }
    /// Point sources at (n − (N−1)/2)·d with phase β·(n − (N−1)/2).
    func discrete(count n: Int, spacing d: Double, beta: Double, axis: SIMD3<Double>, _ text: String) -> RF.ApertureDistribution {
      let centre = Double(n - 1) / 2
      let offsets = (0..<n).map { Double($0) - centre }
      var buffer = RF.IQBuffer(count: n)
      for (k, o) in offsets.enumerated() {
        buffer.i[k] = Float(cos(beta * o))
        buffer.q[k] = Float(sin(beta * o))
      }
      return RF.ApertureDistribution(
        positions: offsets.map { $0 * d }, spacing: d, samples: buffer, axis: axis, isDiscrete: true, description: text)
    }

    switch p.style {
    case .phasedArray:
      let kd = 2 * Double.pi * p.arraySpacing
      let ts = p.steerTheta * Double.pi / 180
      let ps = p.steerPhi * Double.pi / 180
      if plane == .e {
        return discrete(count: p.arrayNx, spacing: p.arraySpacing, beta: -kd * sin(ts) * cos(ps), axis: x,
                        "\(p.arrayNx) elements along x, progressive phase β = −kd·u₀")
      }
      return discrete(count: p.arrayNy, spacing: p.arraySpacing, beta: -kd * sin(ts) * sin(ps), axis: y,
                      "\(p.arrayNy) elements along y, progressive phase β = −kd·v₀")
    case .horn:
      if plane == .e {
        return continuous(halfLength: p.hornB / 2, axis: x, "uniform TE₁₀ field across the E-plane side B") { _ in 1 }
      }
      return continuous(halfLength: p.hornA / 2, axis: y, "TE₁₀ cosine cos(πy/A) across the H-plane side A") { cos(Double.pi * $0 / p.hornA) }
    case .dish:
      let r = p.dishDiameter / 2
      return continuous(halfLength: r, axis: plane == .e ? x : y, "uniform disc projected on the axis, √(R² − x²)") { (max(0, r * r - $0 * $0)).squareRoot() }
    case .patch:
      let design = patchDesign
      if plane == .e {
        return discrete(count: 2, spacing: design.effectiveLength / wavelength, beta: 0, axis: x, "two radiating slots L_e apart")
      }
      return continuous(halfLength: design.width / wavelength / 2, axis: y, "uniform field along the slot width W") { _ in 1 }
    case .dipole, .monopole:
      guard plane == .e else { return nil }
      let l = p.style == .dipole ? p.dipoleLength : 2 * p.monopoleHeight
      let text = p.style == .dipole ? "sinusoidal current sin k(L/2 − |z|)" : "sinusoidal current on the monopole and its image"
      return continuous(halfLength: l / 2, axis: z, text) { sin(2 * Double.pi * (l / 2 - abs($0))) }
    case .shortDipole:
      guard plane == .e else { return nil }
      let l = p.shortDipoleLength
      return continuous(halfLength: l / 2, axis: z, "triangular current 1 − 2|z|/l") { 1 - 2 * abs($0) / l }
    case .yagi:
      guard plane == .e else { return nil }
      let n = min(max(p.yagiElements, 3), 20)
      let kd = 2 * Double.pi * p.yagiSpacing
      return discrete(count: n, spacing: p.yagiSpacing, beta: -(kd + 2.92 / Double(n)), axis: z,
                      "\(n) elements along the boom, Hansen–Woodyard phase")
    case .helix, .smallLoop, .pifa:
      return nil
    }
  }
}
