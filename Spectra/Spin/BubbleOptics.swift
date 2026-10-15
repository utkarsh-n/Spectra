import Foundation

/// Real optics for the Spin bubble's skins (`gyre-integration.md` §5.1, §5.2): the soap film
/// is an Airy thin-film interferometer and the glass orb disperses by Sellmeier.
nonisolated enum BubbleOptics {
  /// Glass for the orb.
  enum Glass: String, CaseIterable, Codable, Sendable, Hashable {
    /// Fused silica, Malitson 1965.
    case fusedSilica
    /// Schott N-BK7.
    case nbk7
  }

  /// Refractive index of `glass` at vacuum wavelength `lambda` (m), three-term Sellmeier.
  /// 530 nm: fused silica 1.46080, N-BK7 1.51958.
  static func index(_ glass: Glass, wavelength lambda: Double) -> Double {
    let u = lambda * 1e6  // µm
    let u2 = u * u
    switch glass {
    case .fusedSilica:
      let a = 0.696_166_3 * u2 / (u2 - 0.068_404_3 * 0.068_404_3)
      let b = 0.407_942_6 * u2 / (u2 - 0.116_241_4 * 0.116_241_4)
      let c = 0.897_479_4 * u2 / (u2 - 9.896_161 * 9.896_161)
      return (1 + a + b + c).squareRoot()
    case .nbk7:
      let a = 1.039_612_12 * u2 / (u2 - 0.006_000_698_67)
      let b = 0.231_792_344 * u2 / (u2 - 0.020_017_914_4)
      let c = 1.010_469_45 * u2 / (u2 - 103.560_653)
      return (1 + a + b + c).squareRoot()
    }
  }

  /// spectra-lab's water Cauchy fit n = 1.3251 + 2946/λ²(nm): 1.3323, 1.3356, 1.3396 at
  /// 640, 530, 450 nm.
  static func waterIndex(wavelength lambda: Double) -> Double {
    let nm = lambda * 1e9
    return 1.3251 + 2946 / (nm * nm)
  }

  /// Airy reflectance of a free-standing film (index `n`, thickness `d` m) in air at vacuum
  /// wavelength `lambda` and incidence angle `angle`:
  /// R = 2r²(1 − cos δ)/(1 + r⁴ − 2r² cos δ), δ = 4πnd cos θₜ/λ, with the normal-incidence
  /// amplitude r = (n − 1)/(n + 1). n 1.33, 420 nm at 450 nm: 0.0769; d → 10 nm: black film.
  static func filmReflectance(index n: Double, thickness d: Double, wavelength lambda: Double, angle: Double = 0) -> Double {
    let r = (n - 1) / (n + 1)
    let r2 = r * r
    let sinT = sin(angle) / n
    let cosT = (1 - sinT * sinT).squareRoot()
    let delta = 4 * .pi * n * d * cosT / lambda
    let c = cos(delta)
    return 2 * r2 * (1 - c) / (1 + r2 * r2 - 2 * r2 * c)
  }
}
