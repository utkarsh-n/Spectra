import Foundation

/// The camera as a light meter (`sdk-sensors.md` §4.8): exposure settings → EV₁₀₀ → an
/// approximate illuminance. Pure formulas; the camera source feeds them.
///
/// EV₁₀₀ = log₂(N²/t) − log₂(S/100) + offset, where N is the f-number, t the exposure time
/// (s), S the ISO and `offset` the camera's own metering error (`exposureTargetOffset`, EV:
/// positive when the scene is brighter than the settings expose for). Incident-light meter
/// calibration E = (C/100)·2^EV₁₀₀ with C = 250 gives E = 2.5·2^EV₁₀₀ lux (ISO 2720). The
/// phone's camera is not a calibrated meter, so lux is a MODEL estimate (±30–50 %).
nonisolated enum LightMeter {
  /// Incident-meter calibration constant C (lux·s per ISO unit), flat-diffuser convention.
  static let incidentConstant = 250.0

  /// Exposure value at ISO 100 for the camera's settings.
  static func ev100(aperture n: Double, exposure t: Double, iso s: Double, targetOffset: Double = 0) -> Double? {
    guard n > 0, t > 0, s > 0, n.isFinite, t.isFinite, s.isFinite else { return nil }
    let offset = targetOffset.isFinite ? targetOffset : 0
    return log2(n * n / t) - log2(s / 100) + offset
  }

  /// Illuminance (lux) for an EV₁₀₀: E = (C/100)·2^EV.
  static func lux(ev100: Double) -> Double { incidentConstant / 100 * pow(2, ev100) }

  /// The EV₁₀₀ that gives `lux`.
  static func ev100(lux: Double) -> Double { log2(max(lux, 1e-9) / (incidentConstant / 100)) }

  /// A rough name for an illuminance, for the readout caption.
  static func describe(lux: Double) -> String {
    switch lux {
    case ..<1: "Dark room"
    case ..<50: "Dim room"
    case ..<300: "Living room"
    case ..<1000: "Office or kitchen"
    case ..<10_000: "Overcast daylight"
    case ..<50_000: "Daylight"
    default: "Direct sunlight"
    }
  }

  /// Where the lamp's blackbody of temperature `kelvin` peaks (Wien, `Core` `Wave.wienPeak`).
  static func wienPeak(kelvin: Double) -> Double { Wave.wienPeak(kelvin) }

  /// Rolling-shutter sampling (experimental, MODEL): a frame read out top to bottom in about
  /// one frame time gives `rows` light samples per frame, so the row signal runs at
  /// rows × frame rate. Lamp flicker at twice the mains frequency (100 or 120 Hz) then shows
  /// as horizontal bands and as a line in the row signal's spectrum. The readout time is not
  /// published, so the frequency axis is approximate until calibrated.
  static func rowRate(rows: Int, frameRate: Double) -> Double { Double(max(rows, 0)) * max(frameRate, 0) }

  /// How far a flicker line must stand above the row spectrum's median floor (dB). In one
  /// 2048-point spectrum of a steady light, the largest of the ~270 noise bins between 80 and
  /// 400 Hz sits 8–12 dB above the median, so a 10 dB test named noise spikes ("a flicker line
  /// near 109 Hz") as lamp flicker. Behind the probe's 1/4000 s exposure a real 100/120 Hz
  /// line stands about 40 dB up.
  static let flickerMargin: Float = 20

  /// The strongest line in `range` (Hz) of a row-signal spectrum, if it stands `margin` dB
  /// above the spectrum's floor; nil otherwise. The axis is approximate (`rowRate`), so the
  /// search is wide rather than pinned to 100 and 120 Hz.
  static func flickerLine(
    in s: LiveAnalysis.Spectrum, range: ClosedRange<Double> = 80...400, margin: Float = flickerMargin
  ) -> Double? {
    guard s.binWidth > 0, !s.bins.isEmpty else { return nil }
    let lo = max(1, Int((range.lowerBound / s.binWidth).rounded(.up)))
    let hi = min(s.bins.count - 1, Int((range.upperBound / s.binWidth).rounded(.down)))
    guard hi > lo else { return nil }
    var best = lo
    for k in lo...hi where s.bins[k] > s.bins[best] { best = k }
    return s.bins[best] - s.floorDB >= margin ? Double(best) * s.binWidth : nil
  }
}
