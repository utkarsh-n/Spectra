import Foundation

/// One active frequency somewhere in the app, drawn on every tab's `SpectrumStrip` and on
/// the Spectrum tuner. Tapping it jumps to `tab` (`AppModel.focus(_:)`).
nonisolated struct SpectrumMarker: Identifiable, Hashable, Sendable {
  /// Stable and unique across the app, e.g. `"spectrum.A"`, `"radio.carrier"`, `"live.ble"`.
  let id: String
  var label: String
  /// Vacuum wavelength in metres. For non-EM signals (sound, rotor) this is c/f, so the
  /// marker sits where an EM wave of the same frequency would; `isEM == false` draws it in
  /// the ANALOGY colour.
  var lambda: Double
  var provenance: Provenance
  var tab: AppTab
  /// `false` → phosphor/amber analogy colour instead of the band colour (rule R2).
  var isEM: Bool

  init(id: String, label: String, lambda: Double, provenance: Provenance, tab: AppTab, isEM: Bool = true) {
    self.id = id
    self.label = label
    self.lambda = lambda
    self.provenance = provenance
    self.tab = tab
    self.isEM = isEM
  }

  /// Builds a marker from a frequency in hertz.
  init(id: String, label: String, frequency: Double, provenance: Provenance, tab: AppTab, isEM: Bool = true) {
    self.init(
      id: id, label: label, lambda: Self.lambda(forFrequency: frequency), provenance: provenance, tab: tab,
      isEM: isEM)
  }

  /// Frequency in hertz (c/λ).
  var frequency: Double { Self.frequency(forLambda: lambda) }

  /// log₁₀ of the wavelength in metres: the ruler coordinate.
  var logLambda: Double { log10(lambda) }

  /// Speed of light in vacuum, m/s (exact, SI 2019).
  static let speedOfLight = 299_792_458.0

  /// λ = c / f. Returns +∞ for f ≤ 0.
  static func lambda(forFrequency hertz: Double) -> Double {
    hertz > 0 ? speedOfLight / hertz : .infinity
  }

  /// f = c / λ. Returns +∞ for λ ≤ 0.
  static func frequency(forLambda metres: Double) -> Double {
    metres > 0 ? speedOfLight / metres : .infinity
  }

  /// The ruler span every strip draws: log₁₀ λ from −13 (0.1 pm) to 8 (100,000 km).
  static let logRange: ClosedRange<Double> = -13...8
}
