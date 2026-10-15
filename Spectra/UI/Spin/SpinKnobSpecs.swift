import SwiftUI

/// The Spin tab's knobs: the engine's pure ranges and detents (`SpinKnobs`) dressed with a
/// title, glyph, tint and words. Spin-bench knobs are made per species: the electron's
/// times are scaled by u = γ′ₚ/|γₑ| and its frequencies by 1/u, so one picture serves both.
@MainActor
enum SpinKnobSpecs {
  // MARK: Gyroscope

  static let gyroscope: [KnobSpec] = SpinKnobs.gyroscope.map { gyroSpec($0) }

  /// The four on the main screen.
  static let gyroscopeInline: [KnobSpec] = ["motor", "gravity", "magnet", "time"].compactMap { id in
    gyroscope.first { $0.id == "spin-\(id)" }
  }

  private static func gyroSpec(_ r: SpinKnobRange) -> KnobSpec {
    let (glyph, tint, hint): (String, Color, String) =
      switch r.id {
      case "motor": ("ω", Theme.analogy, "Motor speed. The rotor's spin, and with it L, sets how slowly it precesses.")
      case "inertia": ("I", Theme.analogy, "Moment of inertia. More inertia, same motor: more angular momentum.")
      case "gravity": ("g", Theme.muted, "Local gravity. It plays the part B plays for a spin.")
      case "balance": ("ℓ", Theme.analogy, "Where the rotor sits on the axle. Zero is a free gyroscope.")
      case "friction": ("μₖ", Theme.amber, "Pivot and bearing friction. It slowly lets the axis fall.")
      case "air": ("ρ", Theme.amber, "Air drag on the rotor, times the barometer's pressure when it runs.")
      case "magnet": ("μ", Theme.fieldB, "Rotor magnetization. Plus is proton-like, minus electron-like.")
      default: ("D", Theme.dialAmber, "Simulation speed. One means real time.")
      }
    return KnobSpec(
      id: "spin-\(r.id)", title: r.title, glyph: glyph, tint: tint, range: r.range, defaultValue: r.defaultValue,
      logarithmic: r.logarithmic, origin: r.origin, step: r.step < 1 ? r.step : 0,
      detents: r.detents.map { KnobDetent($0.value, $0.label) }, hint: hint,
      format: { value in
        let shown = (r.step >= 1 ? (value / r.step).rounded() * r.step : value) * r.displayScale
        switch r.id {
        case "motor": return "\(Int(shown.rounded())) rpm"
        case "friction", "magnet": return "\(SpectraFormat.significant(shown, 3)) %"
        case "balance": return "\(SpectraFormat.significant(shown, 2)) cm"
        case "gravity": return "\(SpectraFormat.significant(shown, 3)) g"
        default: return "\(SpectraFormat.significant(shown, 3)) ×"
        }
      })
  }

  // MARK: Field

  /// B₀: log, 10 µT … 9.4 T, Earth / fridge magnet / MRI / NMR detents.
  static let b0: KnobSpec = {
    let r = SpinKnobs.b0
    return KnobSpec(
      id: "spin-b0", title: "Field", glyph: "B₀", tint: Theme.fieldB, range: r.range, defaultValue: r.defaultValue,
      logarithmic: true, detents: r.detents.map { KnobDetent($0.value, $0.label) },
      hint: "Field magnitude. Water protons precess at 42.58 MHz per tesla.",
      format: { SpectraFormat.si($0, unit: "T") })
  }()

  // MARK: Spin bench (per species)

  struct Bench {
    let b1: KnobSpec
    let offset: KnobSpec
    let phase: KnobSpec
    let ramp: KnobSpec
    let t1: KnobSpec
    let t2: KnobSpec
    let gradient: KnobSpec
    let isochromats: KnobSpec
    let tau: KnobSpec
    let repetition: KnobSpec
    let slowMotion: KnobSpec

    var drive: [KnobSpec] { [b1, offset, phase, ramp] }
    var relax: [KnobSpec] { [t1, t2, gradient, isochromats] }
    var timing: [KnobSpec] { [tau, repetition, slowMotion] }
    var inline: [KnobSpec] { [b1, offset, t2, gradient] }
    var all: [KnobSpec] { drive + relax + timing }
  }

  static let proton = bench(.protonWater)
  static let electron = bench(.electron)

  static func bench(for species: SpinSpecies) -> Bench { species == .electron ? electron : proton }

  private static func bench(_ species: SpinSpecies) -> Bench {
    let u = SpinModel.timeUnit(species)
    let tag = species == .electron ? "e" : "p"
    func time(_ seconds: Double) -> String { SpectraFormat.si(seconds, unit: "s") }
    func hertz(_ value: Double) -> String {
      abs(value) < 1e-9 ? "0 Hz" : (value < 0 ? "−" : "+") + SpectraFormat.frequency(abs(value))
    }
    // A time detent scaled into the electron's picture says so ("Tap water" is the proton's).
    let scaledNote = species == .electron ? " ÷ \(Int((1 / u).rounded()))" : ""
    func detents(_ r: SpinKnobRange, scale: Double) -> [KnobDetent] {
      r.detents.map { KnobDetent($0.value * scale, scale == 1 ? $0.label : $0.label + scaledNote) }
    }
    let b1 = KnobSpec(
      id: "spin-\(tag)-b1", title: "RF field", glyph: "B₁", tint: Theme.fieldB, range: SpinKnobs.b1.range,
      defaultValue: SpinKnobs.b1.defaultValue, logarithmic: true,
      detents: [KnobDetent(1e-6, "1 µT · π/2 in \(time(species.ninetyDuration(b1: 1e-6)))")],
      hint: "RF amplitude. The Rabi rate is γB₁: a bigger B₁ tips faster.",
      format: { SpectraFormat.si($0, unit: "T") })
    let offset = KnobSpec(
      id: "spin-\(tag)-offset", title: "RF offset", glyph: "Δf", tint: Theme.iceRGB.color,
      range: (SpinKnobs.offset.range.lowerBound / u)...(SpinKnobs.offset.range.upperBound / u), defaultValue: 0,
      origin: 0, step: species == .electron ? 0 : SpinKnobs.offset.step, detents: [KnobDetent(0, "On resonance")],
      hint: "Δf = f_L − f_rf. Off resonance, B_eff tilts and the FID beats at Δf.", format: hertz)
    let phase = KnobSpec(
      id: "spin-\(tag)-phase", title: "Phase", glyph: "φ", tint: Theme.dialPhi, range: SpinKnobs.phase.range,
      defaultValue: 0, detents: detents(SpinKnobs.phase, scale: 1),
      hint: "Direction of B₁ in the rotating frame.",
      format: { "\(Int(($0 * 180 / .pi).rounded()))°" })
    let ramp = KnobSpec(
      id: "spin-\(tag)-ramp", title: "Sweep", glyph: "Ḃ", tint: Theme.fieldB, range: (-2e-6 / u)...(2e-6 / u),
      defaultValue: 0, origin: 0, detents: [KnobDetent(0, "Off · steady field")],
      hint: "A sweep coil ramps B₀ for one record after each pulse, so the FID chirps: a straight line in the Wigner view.",
      format: { value in
        abs(value) < 1e-15 ? "Off" : (value < 0 ? "−" : "+") + SpectraFormat.si(abs(value), unit: "T/s")
      })
    let t1 = KnobSpec(
      id: "spin-\(tag)-t1", title: "Recovery", glyph: "T₁", tint: Theme.dialAmber,
      range: (SpinKnobs.t1.range.lowerBound * u)...(SpinKnobs.t1.range.upperBound * u),
      defaultValue: SpinKnobs.t1.defaultValue * u, logarithmic: true, detents: detents(SpinKnobs.t1, scale: u),
      hint: "Longitudinal relaxation: how fast M grows back along B₀.", format: time)
    let t2 = KnobSpec(
      id: "spin-\(tag)-t2", title: "Decay", glyph: "T₂", tint: Theme.dialAmber,
      range: (SpinKnobs.t2.range.lowerBound * u)...(SpinKnobs.t2.range.upperBound * u),
      defaultValue: SpinKnobs.t2.defaultValue * u, logarithmic: true, detents: detents(SpinKnobs.t2, scale: u),
      hint: "Transverse relaxation, the loss an echo cannot undo.", format: time)
    let gradient = KnobSpec(
      id: "spin-\(tag)-gradient", title: "Gradient", glyph: "G", tint: Theme.fieldB, range: SpinKnobs.gradient.range,
      defaultValue: SpinKnobs.gradient.defaultValue, detents: detents(SpinKnobs.gradient, scale: 1),
      hint: "Field gradient across the 10 cm sample: the isochromats fan out and the FID dephases.",
      format: { "\(SpectraFormat.significant($0 * 1e6, 3)) µT/m" })
    let isochromats = KnobSpec(
      id: "spin-\(tag)-isochromats", title: "Isochromats", glyph: "N", tint: Theme.muted,
      range: SpinKnobs.isochromats.range, defaultValue: SpinKnobs.isochromats.defaultValue, logarithmic: true,
      detents: detents(SpinKnobs.isochromats, scale: 1),
      hint: "How many spin packets stand in for the sample.", format: { "\(Int($0.rounded()))" })
    let tau = KnobSpec(
      id: "spin-\(tag)-tau", title: "Delay", glyph: "τ", tint: Theme.dialAmber, range: (0.005 * u)...(1 * u),
      defaultValue: 0.1 * u, logarithmic: true, detents: [KnobDetent(0.1 * u, "Echo at \(time(0.2 * u))")],
      hint: "Echo half-time (the echo forms at 2τ), or the inversion time.", format: time)
    let repetition = KnobSpec(
      id: "spin-\(tag)-tr", title: "Repeat", glyph: "TR", tint: Theme.dialAmber, range: (0.5 * u)...(10 * u),
      defaultValue: 3 * u, logarithmic: true, detents: [KnobDetent(3 * u, "\(time(3 * u))")],
      hint: "Time between repeated sequences.", format: time)
    let slowMotion = KnobSpec(
      id: "spin-\(tag)-slow", title: "Pace", glyph: "κ", tint: Theme.dialAmber, range: 0.05...1, defaultValue: 1,
      logarithmic: true,
      detents: [KnobDetent(1, species == .electron ? "Proton pace" : "Real time"), KnobDetent(0.1, "Ten times slower")],
      hint: "Display pace. One plays the proton bench in real time.",
      format: { "×\(SpectraFormat.significant($0, 2))" })
    return Bench(
      b1: b1, offset: offset, phase: phase, ramp: ramp, t1: t1, t2: t2, gradient: gradient, isochromats: isochromats,
      tau: tau, repetition: repetition, slowMotion: slowMotion)
  }
}
