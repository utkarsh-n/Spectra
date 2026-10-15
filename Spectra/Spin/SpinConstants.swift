import Foundation

/// CODATA 2022 constants for the spin engine (NIST `allascii.txt`, 2022 adjustment, read
/// 3 Oct 2026). Gyromagnetic ratios are signed: μ = γS, so γ > 0 for the proton and
/// γ < 0 for the electron, neutron and helion.
///
/// `Core/SI` keeps the CODATA 2018 electron mass and proton γ for spectra-lab parity. The
/// spin engine needs the 2022 set: the electron's spin/cyclotron ratio 1 + aₑ only closes to
/// 1e-13 when γₑ and mₑ come from the same adjustment.
nonisolated enum SpinConstants {
  /// Speed of light, m/s (exact).
  static let c = 299_792_458.0
  /// Planck constant, J·s (exact).
  static let h = 6.626_070_15e-34
  /// Reduced Planck constant, J·s.
  static let hbar = h / (2 * Double.pi)
  /// Elementary charge, C (exact).
  static let e = 1.602_176_634e-19
  /// Boltzmann constant, J/K (exact).
  static let kB = 1.380_649e-23
  /// Avogadro constant, 1/mol (exact).
  static let avogadro = 6.022_140_76e23
  /// Vacuum magnetic permeability μ₀, N/A².
  static let mu0 = 1.256_637_061_27e-6
  /// Electron mass, kg.
  static let electronMass = 9.109_383_7139e-31
  /// Proton mass, kg.
  static let protonMass = 1.672_621_925_95e-27
  /// Electron magnetic-moment anomaly aₑ = (|gₑ| − 2)/2.
  static let electronAnomaly = 1.159_652_180_46e-3
  /// Electron g-factor (negative: the moment points against the spin).
  static let electronGFactor = -2.002_319_304_360_92
  /// Proton magnetic moment in nuclear magnetons, μₚ/μ_N.
  static let protonMomentNuclearMagnetons = 2.792_847_344_63
  /// Bohr magneton, J/T.
  static let bohrMagneton = 9.274_010_0657e-24
  /// Nuclear magneton, J/T.
  static let nuclearMagneton = 5.050_783_7393e-27
  /// Standard gravity, m/s².
  static let standardGravity = 9.806_65

  /// γₚ/2π for a free proton, Hz/T.
  static let gammaProtonHzPerT = 42.577_478_461e6
  /// γ′ₚ/2π for protons in water (spherical sample, 25 °C), Hz/T. The NMR default.
  static let gammaProtonShieldedHzPerT = 42.576_385_43e6
  /// γₑ/2π for a free electron, Hz/T (CODATA tabulates the magnitude 28 024.951 3861 MHz/T).
  static let gammaElectronHzPerT = -28_024.951_3861e6
  /// γₙ/2π for a free neutron, Hz/T (magnitude 29.164 6935 MHz/T).
  static let gammaNeutronHzPerT = -29.164_6935e6
  /// γ′ₕ/2π for ³He nuclei in ³He gas (spherical sample, 25 °C), Hz/T (magnitude 32.434 100 033 MHz/T).
  static let gammaHelionShieldedHzPerT = -32.434_100_033e6

  /// Protons per cubic metre in liquid water at 997 kg/m³ (molar mass 18.015 28 g/mol),
  /// the spin density used for the Curie magnetization in `gyre-integration.md` §4.1.
  static let waterProtonDensity = 2 * 997 / 0.018_015_28 * avogadro
}
