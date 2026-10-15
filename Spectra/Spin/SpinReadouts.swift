import Foundation

/// Every number the Spin tab's field chips show for one |B| (`gyre-integration.md` §4.1,
/// "Readout chips"): the water-proton line and its pitch, the electron's spin and cyclotron
/// lines with the g − 2 beat, and whether the electron line sits in the AM broadcast band.
/// All MODEL numbers driven by a LIVE (or knob) |B|.
nonisolated struct SpinFieldReadout: Sendable, Hashable {
  /// |B| (tesla).
  let field: Double
  /// ¹H in water (shielded γ′ₚ), Hz. 50 µT: 2128.8192715 Hz.
  let protonHz: Double
  /// Electron spin precession |γₑ|B/2π, Hz. 50 µT: 1.401247569305 MHz.
  let electronHz: Double
  /// Electron cyclotron eB/2πmₑ, Hz. 50 µT: 1.3996244917 MHz.
  let electronCyclotronHz: Double
  /// The anomaly beat f_s − f_c = aₑf_c, Hz. 50 µT: 1623.1 Hz.
  let anomalyBeatHz: Double
  /// Append "AM band" to the electron chip only while 530 kHz ≤ f ≤ 1700 kHz (true for
  /// 18.9–60.7 µT; corrected in review).
  let electronInAMBand: Bool
  /// Free-space wavelength of the proton line (m), for the strip marker. 50 µT: 140.8 km.
  let protonWavelength: Double
  /// Free-space wavelength of the electron line (m). 50 µT: 213.9 m.
  let electronWavelength: Double
  /// What "Hear it" plays for the proton line (true pitch below 20 kHz, else MAPPED).
  let protonVoice: LarmorVoice
  /// What a mapped electron voice would play (always MAPPED: MHz).
  let electronVoice: LarmorVoice

  init(field: Double) {
    let b = abs(field)
    self.field = b
    protonHz = SpinSpecies.protonWater.larmorHz(field: b)
    electronHz = SpinSpecies.electron.larmorHz(field: b)
    electronCyclotronHz = Gyration.cyclotronHz(.electron, field: b)
    anomalyBeatHz = electronHz - electronCyclotronHz
    electronInAMBand = LarmorSonification.isInAMBroadcastBand(electronHz)
    protonWavelength = SpinSpecies.protonWater.larmorWavelength(field: b)
    electronWavelength = SpinSpecies.electron.larmorWavelength(field: b)
    protonVoice = LarmorSonification.voice(forFrequency: protonHz)
    electronVoice = LarmorSonification.voice(forFrequency: electronHz)
  }

  /// Proton pitch jitter (Hz RMS) for magnetometer noise `fieldNoise` (tesla RMS):
  /// 42.58 Hz per µT. Show it next to the calibration state.
  func protonJitterHz(fieldNoise: Double) -> Double {
    LarmorSonification.pitchJitterHz(species: .protonWater, fieldNoise: fieldNoise)
  }
}

/// The drive numbers for the Drive page (`SPEC-features.md` §4): Rabi f₁ and Ω₁ = |γ|B₁,
/// pulse lengths, the effective-field tilt off resonance and the largest inversion it allows.
nonisolated struct SpinDriveReadout: Sendable, Hashable {
  /// Rabi frequency f₁ (Hz). Water, 1 µT: 42.576 Hz.
  let rabiHz: Double
  /// Rabi angular frequency Ω₁ = |γ|B₁ (rad/s).
  let rabiAngular: Double
  /// Resonant π/2 length (s). Water, 1 µT: 5.872 ms.
  let ninetyDuration: Double
  /// Resonant π length (s). Water, 1 µT: 11.744 ms.
  let oneEightyDuration: Double
  /// √(f₁² + Δf²) (Hz). f₁ 42.576, Δf 10: 43.735 Hz.
  let effectiveHz: Double
  /// Tilt of B_eff from +z (rad). f₁ 42.576, Δf 10: 76.8°.
  let effectiveTilt: Double
  /// f₁²/(f₁² + Δf²): the largest inversion probability (not the largest |M_xy|).
  let maxInversionProbability: Double

  init(species: SpinSpecies, b1: Double, offsetHz: Double) {
    rabiHz = species.rabiHz(b1: b1)
    rabiAngular = species.rabiAngular(b1: b1)
    ninetyDuration = b1 != 0 ? species.ninetyDuration(b1: b1) : .infinity
    oneEightyDuration = b1 != 0 ? species.oneEightyDuration(b1: b1) : .infinity
    effectiveHz = Bloch.effectiveHz(rabiHz: rabiHz, offsetHz: offsetHz)
    effectiveTilt = Bloch.effectiveFieldTilt(rabiHz: rabiHz, offsetHz: offsetHz)
    maxInversionProbability = Bloch.maxInversionProbability(rabiHz: rabiHz, offsetHz: offsetHz)
  }
}
