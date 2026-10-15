import Foundation

/// Physical constants, SI (port of spectra-lab `core/constants.js`). The exact values are the
/// 2019 SI defining constants; the rest are CODATA 2018 recommended values.
///
/// Derived constants keep the JS operand order, so every value is bit-identical to the web
/// prototype (checked by the `constants` parity category).
nonisolated enum SI {
  /// Speed of light in vacuum, m/s (exact).
  static let c: Double = 299_792_458
  /// Planck constant, J·s (exact).
  static let h: Double = 6.62607015e-34
  /// Reduced Planck constant ħ = h/2π, J·s.
  static let hbar: Double = h / (2 * Double.pi)
  /// Elementary charge, C (exact).
  static let e: Double = 1.602176634e-19
  /// Boltzmann constant, J/K (exact).
  static let kB: Double = 1.380649e-23
  /// Avogadro constant, 1/mol (exact).
  static let nA: Double = 6.02214076e23
  /// Vacuum permittivity, F/m.
  static let eps0: Double = 8.8541878128e-12
  /// Vacuum permeability, N/A².
  static let mu0: Double = 1.25663706212e-6
  /// Electron mass, kg.
  static let me: Double = 9.1093837015e-31
  /// Electron rest energy, eV.
  static let meEV: Double = 510998.95
  /// Electron-to-proton mass ratio.
  static let meOverMp: Double = 1 / 1836.15267343
  /// Rydberg constant R∞, 1/m.
  static let rydbergInf: Double = 10973731.56816
  /// Reduced-mass Rydberg constant for hydrogen-1, 1/m.
  static let rHydrogen: Double = rydbergInf / (1 + meOverMp)
  /// Wien displacement constant, m·K.
  static let wienB: Double = 2.897771955e-3
  /// Proton gyromagnetic ratio over 2π, Hz/T (CODATA 2018, kept for parity with the web lab's
  /// 400/60 MHz NMR modes; CODATA 2022 differs by 1.3e-9).
  static let gammaProtonHzPerT: Double = 42.577478518e6
  /// Shielded proton gyromagnetic ratio γ′ₚ/2π, Hz/T: protons in a spherical H₂O sample at
  /// 25 °C (CODATA 2022). Native extension: what Earth-field NMR of water actually measures
  /// (gyre-integration.md §4.1, 2128.82 Hz at 50 µT), and the value the Spin engine uses for
  /// water protons.
  static let gammaProtonShieldedHzPerT: Double = 42.57638543e6

  /// hc/e, eV·m (≈ 1.239841984e-6).
  static let hcEVm: Double = (h * c) / e
  /// eV per particle → kcal/mol (thermochemical calorie).
  static let eVToKcalPerMol: Double = (e * nA) / 4184
  /// eV per particle → kJ/mol.
  static let eVToKJPerMol: Double = (e * nA) / 1000
  /// Pair-production threshold 2mₑc², eV.
  static let pairThresholdEV: Double = 2 * meEV
  /// Conventional threshold for ionizing radiation, eV (~124 nm).
  static let ionizingEV: Double = 10
  /// Photon energy at the violet edge (400 nm), eV (≈ 3.10).
  static let visibleEdgeEV: Double = hcEVm / 400e-9
}
