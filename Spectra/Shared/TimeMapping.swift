import Foundation

/// How a visible oscillation relates to wall-clock time (coherence rule R3). Every view that
/// animates a wave declares one, and the `Transport` chip prints it.
nonisolated enum TimeMapping: Equatable, Sendable {
  /// One displayed second is one real second (gyroscope, magnetometer, audio envelopes).
  case realTime
  /// Slowed down: the display runs `factor` times slower than reality (factor > 1).
  /// spectra-lab's κ: factor = f_ref / κ for κ display cycles per second.
  case slowed(factor: Double)
  /// A rotating frame at `fRef` hertz: you see the difference frequency f − f_ref
  /// (NMR rotating frame, a mixer's baseband, the IQ view).
  case heterodyned(fRef: Double)

  /// Badge text: "REAL TIME", "κ-SLOWED" ("SPED UP" when the factor is below 1), "HETERODYNED".
  var badge: String {
    switch self {
    case .realTime: "REAL TIME"
    case .slowed(let factor) where factor > 0 && factor < 1: "SPED UP"
    case .slowed: "κ-SLOWED"
    case .heterodyned: "HETERODYNED"
    }
  }

  /// The detail after the badge: "1 : 1", "×1.8 × 10¹⁵ slower" (or "×2 faster" when the
  /// factor is below 1), "@ 2.13 kHz".
  var detail: String {
    switch self {
    case .realTime:
      "1 : 1"
    case .slowed(let factor) where factor > 0 && factor < 1:
      // A time knob above 1× (Spin's rotor) speeds the display up; say so plainly.
      "×\(SpectraFormat.scientific(1 / factor, digits: 2)) faster"
    case .slowed(let factor):
      "×\(SpectraFormat.scientific(factor, digits: 2)) slower"
    case .heterodyned(let fRef):
      "@ \(SpectraFormat.frequency(fRef))"
    }
  }

  /// Simulated seconds per displayed second (D in `gyre-integration.md` §4.8).
  var simulatedSecondsPerSecond: Double {
    switch self {
    case .realTime, .heterodyned: 1
    case .slowed(let factor): factor > 0 ? 1 / factor : 0
    }
  }

  /// The frequency you actually see on screen for a signal at `frequency` hertz.
  func displayedFrequency(of frequency: Double) -> Double {
    switch self {
    case .realTime: abs(frequency)
    case .slowed(let factor): factor > 0 ? abs(frequency) / factor : 0
    case .heterodyned(let fRef): abs(frequency - fRef)
    }
  }

  /// True when the displayed frequency exceeds half the frame rate: the picture is aliasing
  /// and the transport shows an ALIASED chip.
  func isAliased(frequency: Double, frameRate: Double) -> Bool {
    guard frameRate > 0 else { return false }
    return displayedFrequency(of: frequency) > frameRate / 2
  }

  /// Where a frequency appears after sampling at `rate` (|f − rate·round(f/rate)|).
  /// 60 Hz sampled at 99.8 Hz appears at 39.8 Hz.
  static func aliasedFrequency(_ frequency: Double, sampleRate rate: Double) -> Double {
    guard rate > 0 else { return frequency }
    return abs(frequency - rate * (frequency / rate).rounded())
  }
}
