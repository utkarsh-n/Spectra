import Foundation

/// A spin-½ particle the Spin tab can put in a field, with its CODATA 2022 gyromagnetic ratio.
///
/// Sign convention: μ = γS and dM/dt = γ M × B, so M precesses about B with angular
/// velocity −γB. Viewed from the tip of B, protons (γ > 0) turn clockwise and electrons,
/// neutrons and ³He (γ < 0) counterclockwise. Equilibrium magnetization points along +B
/// for every species.
nonisolated enum SpinSpecies: String, CaseIterable, Codable, Sendable, Hashable {
  /// Protons in water (shielded γ′ₚ): what an Earth's-field NMR rig hears. The default.
  case protonWater
  /// A free proton (bare γₚ).
  case proton
  /// A free electron (ESR).
  case electron
  /// A free neutron.
  case neutron
  /// ³He nuclei in ³He gas (shielded γ′ₕ), the low-field magnetometry and MRI gas.
  case helion

  /// γ/2π in Hz/T, signed.
  var gammaHzPerT: Double {
    switch self {
    case .protonWater: SpinConstants.gammaProtonShieldedHzPerT
    case .proton: SpinConstants.gammaProtonHzPerT
    case .electron: SpinConstants.gammaElectronHzPerT
    case .neutron: SpinConstants.gammaNeutronHzPerT
    case .helion: SpinConstants.gammaHelionShieldedHzPerT
    }
  }

  /// γ in rad s⁻¹ T⁻¹, signed.
  var gamma: Double { 2 * .pi * gammaHzPerT }

  /// Short label for chips: "¹H₂O", "p⁺", "e⁻", "n", "³He".
  var symbol: String {
    switch self {
    case .protonWater: "¹H₂O"
    case .proton: "p⁺"
    case .electron: "e⁻"
    case .neutron: "n"
    case .helion: "³He"
    }
  }

  /// Plain name for pickers and VoiceOver.
  var title: String {
    switch self {
    case .protonWater: "Protons in water"
    case .proton: "Free proton"
    case .electron: "Electron"
    case .neutron: "Neutron"
    case .helion: "Helium-3"
    }
  }

  /// Sense of free precession about B, viewed from the tip of B.
  var precessionSense: PrecessionSense { gammaHzPerT > 0 ? .clockwise : .counterclockwise }

  /// Larmor frequency |γ|B/2π in Hz for a field magnitude `field` (tesla).
  func larmorHz(field: Double) -> Double { abs(gammaHzPerT * field) }

  /// Larmor angular frequency |γ|B in rad/s.
  func larmorAngular(field: Double) -> Double { abs(gamma * field) }

  /// The free-space wavelength c/f_L of the Larmor line, for the Spectrum strip marker.
  /// 50 µT protons in water: 140.8 km.
  func larmorWavelength(field: Double) -> Double {
    let f = larmorHz(field: field)
    return f > 0 ? SpinConstants.c / f : .infinity
  }

  /// The field magnitude (tesla) whose Larmor frequency is `frequency` hertz.
  func field(forLarmorHz frequency: Double) -> Double { abs(frequency / gammaHzPerT) }

  /// Rabi frequency f₁ = |γ|B₁/2π (Hz) for a rotating RF field of amplitude `b1` (tesla).
  func rabiHz(b1: Double) -> Double { abs(gammaHzPerT * b1) }

  /// Rabi angular frequency Ω₁ = |γ|B₁ (rad/s), the "Rabi Ω = γB₁" readout.
  func rabiAngular(b1: Double) -> Double { abs(gamma * b1) }

  /// Duration of a resonant π/2 pulse, 1/(4f₁). B₁ = 1 µT, protons in water: 5.872 ms.
  func ninetyDuration(b1: Double) -> Double { 1 / (4 * rabiHz(b1: b1)) }

  /// Duration of a resonant π pulse, 1/(2f₁). B₁ = 1 µT, protons in water: 11.744 ms.
  func oneEightyDuration(b1: Double) -> Double { 1 / (2 * rabiHz(b1: b1)) }

  /// Thermal polarization P = |γ|ħB/(2kT) of spin-½ at `temperature` kelvin (high-T limit).
  /// Protons in water at 50 µT and 298.15 K: 1.7 × 10⁻¹⁰.
  func thermalPolarization(field: Double, temperature: Double) -> Double {
    abs(gamma) * SpinConstants.hbar * field / (2 * SpinConstants.kB * temperature)
  }

  /// Curie magnetization M₀ = Nγ²ħ²B/(4kT) in A/m for `density` spins per m³.
  /// Water at 50 µT, 298.15 K: 1.6 × 10⁻⁷ A/m.
  func curieMagnetization(field: Double, temperature: Double, density: Double = SpinConstants.waterProtonDensity) -> Double {
    density * gamma * gamma * SpinConstants.hbar * SpinConstants.hbar * field / (4 * SpinConstants.kB * temperature)
  }
}

/// Which way a moment precesses about the field, viewed from the tip of B.
nonisolated enum PrecessionSense: String, Codable, Sendable, Hashable {
  case clockwise
  case counterclockwise

  /// −1 for clockwise, +1 for counterclockwise: the sign of the precession angular
  /// velocity along B.
  var sign: Double { self == .clockwise ? -1 : 1 }
}
