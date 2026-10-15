import Foundation

/// Whether a voice plays the physical frequency or a mapped stand-in.
nonisolated enum PitchMode: String, Codable, Sendable, Hashable {
  /// The true precession frequency (Earth-field protons, ~2.1 kHz).
  case truePitch
  /// spectra-lab's log mapping into the audible band; badge MAPPED.
  case mapped
}

/// What the synth should play for a precessing spin.
nonisolated struct LarmorVoice: Sendable, Hashable {
  /// The physical frequency (Hz).
  var physicalHz: Double
  /// What comes out of the speaker (Hz).
  var audibleHz: Double
  var mode: PitchMode
}

/// Sonification rules for the Spin tab's "Hear it" (`gyre-integration.md` §4.1, §4.9):
/// play the true Larmor pitch whenever it is audible, otherwise spectra-lab's mapped pitch
/// with a MAPPED badge. Electron lines (MHz) are only ever heard mapped.
nonisolated enum LarmorSonification {
  /// Highest frequency played at true pitch (Hz). Water protons pass it above |B| = 470 µT,
  /// which a 10 × 3 mm NdFeB disc reaches within 4.7–4.9 cm (corrected in review).
  static let audibleCeiling = 20_000.0
  /// Lowest frequency played at true pitch (Hz).
  static let audibleFloor = 20.0
  /// |B| smoothing time constant (s) so magnetometer noise does not warble the tone.
  static let fieldSmoothingTime = 0.25

  /// spectra-lab's mapped pitch 110·2^(4(log₁₀f − 5.5)/16) Hz.
  /// 60 Hz → 57.7 Hz, 1.40125 MHz → 123.0 Hz, 2.44 GHz → 215.7 Hz, 545 THz → 545.1 Hz.
  static func mappedPitch(forFrequency f: Double) -> Double {
    guard f > 0 else { return 0 }
    return 110 * pow(2, 4 * (log10(f) - 5.5) / 16)
  }

  /// The voice for a physical frequency: true pitch inside 20 Hz…20 kHz (unless
  /// `preferTrue` is off), mapped otherwise.
  static func voice(forFrequency f: Double, preferTrue: Bool = true) -> LarmorVoice {
    let physical = abs(f)
    if preferTrue, physical >= audibleFloor, physical <= audibleCeiling {
      return LarmorVoice(physicalHz: physical, audibleHz: physical, mode: .truePitch)
    }
    return LarmorVoice(physicalHz: physical, audibleHz: mappedPitch(forFrequency: physical), mode: .mapped)
  }

  /// The voice for `species` in a field of magnitude `field` tesla.
  static func voice(species: SpinSpecies, field: Double, preferTrue: Bool = true) -> LarmorVoice {
    voice(forFrequency: species.larmorHz(field: field), preferTrue: preferTrue)
  }

  /// Pitch jitter σ_f = (|γ|/2π)·σ_B caused by field noise `fieldNoise` (tesla RMS).
  /// Protons: 42.58 Hz per µT.
  static func pitchJitterHz(species: SpinSpecies, fieldNoise: Double) -> Double {
    abs(species.gammaHzPerT) * abs(fieldNoise)
  }

  /// The field above which `species` leaves true pitch (tesla). Water protons: 469.7 µT.
  static func truePitchCeilingField(species: SpinSpecies) -> Double {
    species.field(forLarmorHz: audibleCeiling)
  }

  /// Medium-wave AM broadcast band edges (Hz), 530–1700 kHz [S].
  static let amBroadcastBand = 530e3...1700e3

  /// Whether a line sits in the AM broadcast band, for the conditional "AM band" chip on the
  /// electron readout. Electrons qualify only for 18.9 µT < |B| < 60.7 µT; at 65 µT the line
  /// is 1.82 MHz, in the 160 m amateur band (corrected in review).
  static func isInAMBroadcastBand(_ frequency: Double) -> Bool { amBroadcastBand.contains(abs(frequency)) }
}

/// What the Spin tab's synth voices should do for one frame: the FID voice (true or mapped
/// pitch, ring-down) and the rotor hum, whose nod modulation runs at the true inertial nod
/// × the time scale D instead of Gyre's 2·precession + 1.5 Hz (`gyre-integration.md` §4.9).
nonisolated struct SpinSoundParameters: Sendable, Hashable {
  /// The FID voice (physical and audible pitch, MAPPED or not).
  var fid: LarmorVoice
  /// FID ring-down time T₂* (s) for the synth's envelope.
  var fidDecay: Double
  /// Rotor hum fundamental (Hz): spin rate × 6 blades, wall-clock (× D).
  var rotorBladePassHz: Double
  /// Rotor hum amplitude-modulation rate (Hz): the inertial nod × D, wall-clock.
  var rotorNodHz: Double

  /// - Parameters:
  ///   - species: the spin being heard.
  ///   - field: |B₀| (tesla), already smoothed with τ = 0.25 s.
  ///   - t2Star: the FID's decay time (s).
  ///   - pitch: the Listen page's True/Mapped switch.
  ///   - rotor: the heavy top's telemetry (rpm, nod rate in simulated time).
  ///   - timeScale: D, simulated seconds per wall second.
  init(species: SpinSpecies, field: Double, t2Star: Double, pitch: PitchMode, rotor: HeavyTopTelemetry?, timeScale: Double = 1) {
    fid = LarmorSonification.voice(species: species, field: field, preferTrue: pitch == .truePitch)
    fidDecay = t2Star
    let d = max(timeScale, 0)
    rotorBladePassHz = abs(rotor?.rpm ?? 0) / 60 * 6 * d
    rotorNodHz = (rotor?.nutationHz ?? 0) * d
  }
}
