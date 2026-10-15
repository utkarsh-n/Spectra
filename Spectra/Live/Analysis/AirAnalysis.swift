import Foundation

/// The barometer's air as a radio medium (`gyre-integration.md` §4.5), put together from the
/// engines: P.453 refractivity, k-factor, radio horizon and GNSS zenith hydrostatic delay from
/// the Spin engine's `AirHere`, and P.676 oxygen absorption from the RF engine's atmosphere.
/// Temperature and humidity are knobs: no public iOS API measures them.
nonisolated enum AirAnalysis {
  struct Result: Sendable, Equatable {
    /// Radio refractivity N (N-units) and its dry and wet parts.
    var refractivity: Double
    var dry: Double
    var wet: Double
    /// n − 1 in parts per million (= N).
    var excessPPM: Double { refractivity }
    /// Effective Earth-radius factor k.
    var kFactor: Double
    /// Radio horizon (m) for the antenna height, and the geometric (k = 1) one.
    var radioHorizon: Double
    var geometricHorizon: Double
    /// GNSS zenith hydrostatic delay: metres, and seconds of light time.
    var zenithDelay: Double
    var zenithDelaySeconds: Double
    /// Oxygen specific attenuation at 60 GHz (dB/km), P.676 with total pressure.
    var oxygen60GHz: Double
    /// Height change per hPa near the ground (m/hPa).
    var metresPerHPa: Double
  }

  /// Water-vapour density (g/m³) for a relative humidity: e from P.453 (`AirHere`), then
  /// ρ = 216.7·e/T, the inverse of the RF engine's `AirState.vapourPressure`.
  static func vapourDensity(pressureHPa p: Double, tempC t: Double, humidity rh: Double) -> Double {
    let e = AirHere.vaporPressure(tempC: t, humidity: rh, pressureHPa: p)
    return 216.7 * e / (t + 273.15)
  }

  /// The P.676 air state for the barometer reading (total-pressure convention, as the RF
  /// engine's API note asks of the Live Air card).
  static func airState(pressureHPa p: Double, tempC t: Double, humidity rh: Double) -> RF.Atmosphere.AirState {
    RF.Atmosphere.AirState(
      pressure: p, temperatureC: t, waterVapourDensity: vapourDensity(pressureHPa: p, tempC: t, humidity: rh), convention: .total)
  }

  static func evaluate(
    pressureHPa p: Double, tempC t: Double, humidity rh: Double, gradient: Double, height: Double,
    latitudeDegrees: Double, ellipsoidalHeight: Double
  ) -> Result {
    let n = AirHere.refractivity(pressureHPa: p, tempC: t, humidity: rh)
    let k = AirHere.kFactor(gradientPerKm: gradient)
    // Past the ducting gradient rays bend more than the Earth: k is negative and the horizon
    // is unbounded.
    let horizon = k > 0 ? AirHere.radioHorizon(height: height, k: k) : .infinity
    let zhd = AirHere.zenithHydrostaticDelay(pressureHPa: p, latitude: latitudeDegrees * .pi / 180, height: ellipsoidalHeight)
    let gas = RF.Atmosphere.gasSpecificAttenuation(frequencyGHz: 60, air: airState(pressureHPa: p, tempC: t, humidity: rh))
    return Result(
      refractivity: n.total, dry: n.dry, wet: n.wet, kFactor: k, radioHorizon: horizon,
      geometricHorizon: AirHere.radioHorizon(height: height, k: 1), zenithDelay: zhd, zenithDelaySeconds: zhd / RF.Const.c,
      oxygen60GHz: gas.oxygen, metresPerHPa: AirHere.metresPerHPa(tempK: t + 273.15, pressureHPa: p))
  }

  /// One-way distance light covers in half a round trip (m): the "speed of light" readout
  /// for a measured RTT.
  static func lightPath(roundTrip seconds: Double) -> Double { RF.Const.c * max(seconds, 0) / 2 }
}
