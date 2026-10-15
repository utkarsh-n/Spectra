import Foundation

/// The air around the phone as a radio medium (`gyre-integration.md` §4.5): ITU-R P.453-14
/// refractivity from pressure, temperature and humidity, the effective-Earth k-factor, the
/// radio horizon and the GNSS zenith hydrostatic delay. Also the barometric factor that sets
/// the Spin rotor's air drag. Used by the Live "Air" card and the Patch Air node.
nonisolated enum AirHere {
  /// Mean Earth radius a (m) for k-factor and horizon.
  static let earthRadius = 6_371_000.0
  /// ISA sea-level pressure (hPa).
  static let standardPressure = 1013.25
  /// Standard refractivity gradient (N-units per km): k ≈ 4/3.
  static let standardGradient = -40.0

  /// Saturation vapour pressure over water (hPa), P.453 eq. 9 with the water enhancement
  /// factor EF = 1 + 10⁻⁴[7.2 + P(0.0320 + 5.9×10⁻⁶ t²)] (−40…+50 °C).
  static func saturationVaporPressure(tempC t: Double, pressureHPa p: Double) -> Double {
    let ef = 1 + 1e-4 * (7.2 + p * (0.0320 + 5.9e-6 * t * t))
    return ef * 6.1121 * exp((18.678 - t / 234.5) * t / (t + 257.14))
  }

  /// Water vapour pressure e = H·e_s/100 (hPa), P.453 eq. 8. `humidity` is RH in percent.
  static func vaporPressure(tempC: Double, humidity: Double, pressureHPa: Double) -> Double {
    humidity / 100 * saturationVaporPressure(tempC: tempC, pressureHPa: pressureHPa)
  }

  /// Radio refractivity N = 77.6 P_d/T + 72 e/T + 3.75×10⁵ e/T² (P.453 eq. 2), with
  /// P_d = P − e (total pressure in). 1013.25 hPa, 15 °C: 272.87 dry, 311.37 at 50 % RH.
  static func refractivity(pressureHPa p: Double, tempC: Double, humidity: Double) -> (n: Double, dry: Double, wet: Double, total: Double) {
    let t = tempC + 273.15
    let e = vaporPressure(tempC: tempC, humidity: humidity, pressureHPa: p)
    let dry = 77.6 * (p - e) / t
    let wet = 72 * e / t + 3.75e5 * e / (t * t)
    let total = dry + wet
    return (1 + total * 1e-6, dry, wet, total)
  }

  /// The P.453 eq. 7 approximation N = (77.6/T)(P + 4810 e/T), within 0.02 % from −50 to +40 °C.
  static func refractivityApproximation(pressureHPa p: Double, tempC: Double, humidity: Double) -> Double {
    let t = tempC + 273.15
    let e = vaporPressure(tempC: tempC, humidity: humidity, pressureHPa: p)
    return 77.6 / t * (p + 4810 * e / t)
  }

  /// Effective Earth-radius factor k = 1/(1 + a·dN/dh·10⁻⁶), dN/dh in N-units per km.
  /// −40 N/km: 1.34199.
  static func kFactor(gradientPerKm g: Double) -> Double {
    1 / (1 + earthRadius / 1000 * g * 1e-6)
  }

  /// The gradient at which rays follow the Earth (k → ∞): −1/a = −157 N/km.
  static var ductingGradient: Double { -1e6 / (earthRadius / 1000) }

  /// Radio horizon √(2kah) (m) for an antenna `height` metres up. 1.5 m, k = 4/3: 5.048 km.
  static func radioHorizon(height: Double, k: Double = 4.0 / 3.0) -> Double {
    (2 * k * earthRadius * max(height, 0)).squareRoot()
  }

  /// Zenith hydrostatic delay (m), Saastamoinen/Davis (IERS Conventions 2010 ch. 9):
  /// 0.0022768·P/(1 − 0.00266 cos 2φ − 2.8×10⁻⁷ H). 1013.25 hPa, 45°, 0 m: 2.30697 m.
  static func zenithHydrostaticDelay(pressureHPa p: Double, latitude: Double, height: Double) -> Double {
    0.002_276_8 * p / (1 - 0.002_66 * cos(2 * latitude) - 0.000_000_28 * height)
  }

  /// Height change per hPa near the ground, H/P = RT/(Mg)/P (m/hPa). 288.15 K: 8.32 m/hPa.
  static func metresPerHPa(tempK: Double = 288.15, pressureHPa: Double = standardPressure) -> Double {
    8.314_462_618 * tempK / (0.028_964_4 * SpinConstants.standardGravity) / pressureHPa
  }

  /// The Spin rotor's air-density factor P/101.325 kPa (Gyre's barometer scaling).
  static func pressureFactor(kilopascals: Double) -> Double { max(kilopascals, 0) / 101.325 }
}
