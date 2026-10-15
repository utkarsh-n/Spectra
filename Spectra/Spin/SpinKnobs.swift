import Foundation

/// A labelled detent on a spin knob. Detents carry physical meaning (Moon, Real NdFeB,
/// Earth field), so the values live with the physics.
nonisolated struct SpinKnobDetent: Sendable, Hashable {
  let value: Double
  let label: String
}

/// The pure part of a Spin-tab knob: range, mapping, default and detents, with Gyre's
/// `KnobSpec` position maths verbatim (`Model/Knobs.swift`). The UI wraps it with a title,
/// symbol, tint and key path (`gyre-integration.md` §3: generic `KnobSpec<Root>`).
nonisolated struct SpinKnobRange: Sendable, Hashable, Identifiable {
  let id: String
  let title: String
  /// Unit as displayed after conversion by `displayScale` ("µT", "Hz", "s", "Pa").
  let unit: String
  /// Model units (SI unless stated).
  let range: ClosedRange<Double>
  let defaultValue: Double
  var logarithmic = false
  /// Where the value arc starts; bipolar knobs light up from their zero.
  var origin: Double? = nil
  var detents: [SpinKnobDetent] = []
  /// Values snap to this step while dragging (0: continuous).
  var step: Double = 0
  /// Multiply a model value by this to get the displayed number (1e6 for µT).
  var displayScale = 1.0

  /// A rotary switch: whole-number positions, each a named detent.
  var isSwitch: Bool { step >= 1 }

  /// Knob position 0…1 of `value`.
  func position(of value: Double) -> Double {
    let v = SpinMath.clamp(value, range.lowerBound, range.upperBound)
    if logarithmic { return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound) }
    return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
  }

  /// Value at knob position 0…1 (snapped to `step`).
  func value(at position: Double) -> Double {
    let p = SpinMath.clamp(position, 0, 1)
    var v =
      logarithmic
      ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
      : range.lowerBound + p * (range.upperBound - range.lowerBound)
    if step > 0 { v = (v / step).rounded() * step }
    return SpinMath.clamp(v, range.lowerBound, range.upperBound)
  }

  var originPosition: Double { position(of: origin ?? range.lowerBound) }

  /// The detent within ±0.004 of knob travel of `value`, if any.
  func detent(at value: Double) -> SpinKnobDetent? {
    detents.first { abs(position(of: $0.value) - position(of: value)) < 0.004 }
  }

  /// Modulation applied in position space, so log knobs modulate musically
  /// (`gyre-integration.md` §7): value(at: position(of: base) + depth·cv).
  func modulated(base: Double, depth: Double, control cv: Double) -> Double {
    value(at: position(of: base) + depth * cv)
  }
}

/// Ranges and detents for every Spin-tab knob (`SPEC-features.md` §4, `gyre-integration.md`
/// §4.1 console pages, Gyre's knob table).
nonisolated enum SpinKnobs {
  // MARK: Gyroscope (Gyre's physics page; Magnet now −1…1)

  static let motor = SpinKnobRange(
    id: "motor", title: "Motor", unit: "rpm", range: 0...12_000, defaultValue: 3000,
    detents: [SpinKnobDetent(value: 0, label: "Off · coasting")], step: 50)
  static let inertia = SpinKnobRange(
    id: "inertia", title: "Inertia", unit: "×", range: 0.25...3, defaultValue: 1, logarithmic: true,
    detents: [SpinKnobDetent(value: 1, label: "Brass disc")])
  static let gravity = SpinKnobRange(
    id: "gravity", title: "Gravity", unit: "g", range: -1...3, defaultValue: 1, origin: 0,
    detents: [
      SpinKnobDetent(value: -1, label: "Inverted"), SpinKnobDetent(value: 0, label: "Zero-g"),
      SpinKnobDetent(value: 0.166, label: "Moon"), SpinKnobDetent(value: 0.38, label: "Mars"),
      SpinKnobDetent(value: 1, label: "Earth"), SpinKnobDetent(value: 2.53, label: "Jupiter"),
    ], step: 0.01)
  static let balance = SpinKnobRange(
    id: "balance", title: "Balance", unit: "cm", range: -1...1, defaultValue: 0.5, origin: 0,
    detents: [
      SpinKnobDetent(value: -1, label: "Hanging"), SpinKnobDetent(value: 0, label: "Balanced · free gyro"),
      SpinKnobDetent(value: 1, label: "Top-heavy"),
    ], step: 0.01, displayScale: HeavyTop.maxOffset * 100)
  static let friction = SpinKnobRange(
    id: "friction", title: "Friction", unit: "%", range: 0...1, defaultValue: 0.25, step: 0.01, displayScale: 100)
  static let air = SpinKnobRange(
    id: "air", title: "Air", unit: "×", range: 0...3, defaultValue: 1,
    detents: [SpinKnobDetent(value: 0, label: "Vacuum"), SpinKnobDetent(value: 1, label: "Sea level")], step: 0.01)
  /// Signed rotor magnetization: + proton-like, − electron-like (`gyre-integration.md` §1).
  static let magnet = SpinKnobRange(
    id: "magnet", title: "Magnet", unit: "%", range: -1...1, defaultValue: 0, origin: 0,
    detents: [
      SpinKnobDetent(value: HeavyTopParams.electronLikeMagnet, label: "Electron-like"),
      SpinKnobDetent(value: 0, label: "Off"),
      SpinKnobDetent(value: HeavyTopParams.realNdFeBMagnet, label: "Real NdFeB"),
      SpinKnobDetent(value: 1, label: "Fantasy"),
    ], displayScale: 100)
  static let time = SpinKnobRange(
    id: "time", title: "Time", unit: "×", range: 0.05...2, defaultValue: 1, logarithmic: true,
    detents: [SpinKnobDetent(value: 0.25, label: "Slow motion"), SpinKnobDetent(value: 1, label: "Real time")])

  static let gyroscope = [motor, inertia, gravity, balance, friction, air, magnet, time]

  // MARK: Field

  /// Manual B₀ (tesla), log, Earth field to a 400 MHz NMR magnet.
  static let b0 = SpinKnobRange(
    id: "b0", title: "B₀", unit: "T", range: 10e-6...9.4, defaultValue: EarthField.typicalField, logarithmic: true,
    detents: [
      SpinKnobDetent(value: 50e-6, label: "Earth 50 µT"), SpinKnobDetent(value: 5e-3, label: "Fridge magnet 5 mT"),
      SpinKnobDetent(value: 1.5, label: "MRI 1.5 T"), SpinKnobDetent(value: 3, label: "MRI 3 T"),
      SpinKnobDetent(value: 9.4, label: "NMR 9.4 T"),
    ])

  // MARK: Drive

  /// B₁ (tesla), 0.1–10 µT log.
  static let b1 = SpinKnobRange(
    id: "b1", title: "B₁", unit: "µT", range: 0.1e-6...10e-6, defaultValue: 1e-6, logarithmic: true,
    detents: [SpinKnobDetent(value: 1e-6, label: "1 µT · π/2 in 5.9 ms")], displayScale: 1e6)
  /// RF offset Δf (Hz).
  static let offset = SpinKnobRange(
    id: "offset", title: "RF offset", unit: "Hz", range: -50...50, defaultValue: 0, origin: 0,
    detents: [SpinKnobDetent(value: 0, label: "On resonance")], step: 0.1)
  /// Phase φ of B₁ (radians), shown in degrees.
  static let phase = SpinKnobRange(
    id: "phase", title: "Phase", unit: "°", range: 0...(2 * .pi), defaultValue: 0,
    detents: [
      SpinKnobDetent(value: 0, label: "x"), SpinKnobDetent(value: .pi / 2, label: "y"),
      SpinKnobDetent(value: .pi, label: "−x"), SpinKnobDetent(value: 1.5 * .pi, label: "−y"),
    ], displayScale: 180 / .pi)

  // MARK: Relax

  static let t1 = SpinKnobRange(
    id: "t1", title: "T₁", unit: "s", range: 0.01...5, defaultValue: 2.5, logarithmic: true,
    detents: [SpinKnobDetent(value: 2.5, label: "Tap water")])
  static let t2 = SpinKnobRange(
    id: "t2", title: "T₂", unit: "s", range: 0.01...5, defaultValue: 2, logarithmic: true,
    detents: [SpinKnobDetent(value: 2, label: "Tap water")])
  /// Field gradient across the sample (T/m), shown in µT/m.
  static let gradient = SpinKnobRange(
    id: "gradient", title: "Gradient", unit: "µT/m", range: 0...10e-6, defaultValue: 1e-6,
    detents: [SpinKnobDetent(value: 0, label: "Uniform"), SpinKnobDetent(value: 1e-6, label: "1 µT/m")],
    displayScale: 1e6)
  static let isochromats = SpinKnobRange(
    id: "isochromats", title: "Isochromats", unit: "", range: 8...256, defaultValue: 64, logarithmic: true,
    detents: [SpinKnobDetent(value: 64, label: "64")], step: 1)

  // MARK: Charges

  /// Bubble air pressure (Pa), log; the Vacuum detent sits at the bottom of the range.
  static let chargeAir = SpinKnobRange(
    id: "chargeAir", title: "Air", unit: "Pa", range: 1e-3...101_325, defaultValue: 1e-3, logarithmic: true,
    detents: [
      SpinKnobDetent(value: 1e-3, label: "Vacuum"), SpinKnobDetent(value: 5, label: "D layer ~5 Pa"),
      SpinKnobDetent(value: 101_325, label: "Sea level"),
    ])
  static let temperature = SpinKnobRange(
    id: "temperature", title: "Temperature", unit: "K", range: 30...3000, defaultValue: 300, logarithmic: true,
    detents: [SpinKnobDetent(value: 300, label: "Room")])
  /// Electric field for E × B drift (V/m).
  static let electricField = SpinKnobRange(
    id: "electricField", title: "E", unit: "V/m", range: -2...2, defaultValue: 0, origin: 0,
    detents: [SpinKnobDetent(value: 0, label: "Off")], step: 0.01)
}
