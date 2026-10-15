import Foundation

/// A field trip (port of spectra-lab `core/presets.js`): sets every source, opens the
/// instrument that tells its story and patches that instrument's settings.
nonisolated struct SpectraPreset: Hashable, Sendable, Identifiable {
  /// Partial decompose settings (JS `decompose: {...}`).
  struct DecomposePatch: Hashable, Sendable {
    var tab: SpectraState.DecomposeSettings.Tab
    var a0: Double? = nil
    var probeMode: Wave.ProbeMode? = nil
  }

  /// Partial lab settings (JS `lab: {...}`).
  struct LabPatch: Hashable, Sendable {
    var sample: SampleKey
    var mode: SampleMode
    var sweep: Double
  }

  let key: String
  let name: String
  let detail: String
  let note: String
  /// The three sources before sanitizing (A, B, C).
  let sources: [WaveSource]
  /// Medium to set (vacuum when nil).
  var medium: Matter.Medium? = nil
  let instrument: SpectraState.Instrument
  /// Bench focus to set, if any.
  var benchFocus: SpecimenKey? = nil
  var decompose: DecomposePatch? = nil
  var lab: LabPatch? = nil

  var id: String { key }

  /// The 14 field trips in menu order.
  static let all: [SpectraPreset] = makeAll()

  /// The preset with this key, if any.
  static func named(_ key: String) -> SpectraPreset? { all.first { $0.key == key } }

  private static func off(_ lambda: Double) -> WaveSource { WaveSource(enabled: false, lambda: lambda) }
  private static func one(_ s: WaveSource) -> [WaveSource] { [s, off(450e-9), off(650e-9)] }

  private static func makeAll() -> [SpectraPreset] {
    [
      SpectraPreset(
        key: "fm", name: "FM radio", detail: "100 MHz \u{00B7} 3.00 m",
        note: "A half-wave dipole antenna (1.5 m) resonates: half a wavelength fits the rods.",
        sources: one(WaveSource(lambda: SI.c / 100e6, e0: 0.01)), instrument: .bench, benchFocus: .antenna),
      SpectraPreset(
        key: "oven", name: "Microwave oven", detail: "2.45 GHz \u{00B7} 12.2 cm",
        note: "Water molecules twist after the field and lag behind it, so the water heats. The 2 mm holes in the door mesh are far smaller than the wave, so it can't get out.",
        sources: one(WaveSource(lambda: SI.c / 2.45e9, e0: 5000)), instrument: .bench, benchFocus: .water),
      SpectraPreset(
        key: "wifi", name: "Wi-Fi through a wall", detail: "5 GHz \u{00B7} 6.0 cm",
        note: "Drywall and glass barely notice it. Metal reflects it, and water (and people) absorb it.",
        sources: one(WaveSource(lambda: SI.c / 5e9, e0: 1)), instrument: .bench, benchFocus: .glass),
      SpectraPreset(
        key: "thermal", name: "Thermal camera", detail: "310 K body \u{00B7} peak 9.3 \u{00B5}m",
        note: "Your body glows in the long-wave infrared. Wien's law puts the peak of a 310 K body at 9.3 \u{00B5}m.",
        sources: one(WaveSource(kind: .thermal, lambda: Wave.wienPeak(310), e0: 30, temperature: 310)),
        instrument: .decompose, decompose: DecomposePatch(tab: .fourier)),
      SpectraPreset(
        key: "prism", name: "Prism", detail: "Three colors in glass",
        note: "Blue, green and red travel at different speeds in glass (n = 1.53, 1.52, 1.51), so a prism bends them by different amounts.",
        sources: [WaveSource(lambda: 450e-9), WaveSource(lambda: 550e-9), WaveSource(lambda: 650e-9)], medium: .glass,
        instrument: .decompose, decompose: DecomposePatch(tab: .fourier)),
      SpectraPreset(
        key: "photo", name: "Photoelectric effect", detail: "Red vs UV on zinc",
        note: "Turn red light up as bright as you like: zinc ejects nothing. A dim UV-C source ejects electrons at once. Energy per photon, not brightness, decides (Einstein, 1905).",
        sources: [WaveSource(lambda: 650e-9, e0: 1e6), WaveSource(enabled: false, lambda: 254e-9, e0: 10), off(550e-9)],
        instrument: .bench, benchFocus: .zinc),
      SpectraPreset(
        key: "balmer", name: "Hydrogen lines", detail: "656 \u{00B7} 486 \u{00B7} 434 \u{00B7} 410 nm",
        note: "The visible Balmer lines from the Rydberg formula. Sweep to see the ultraviolet Lyman and infrared Paschen series too.",
        sources: one(WaveSource(lambda: 656.47e-9)), instrument: .lab,
        lab: LabPatch(sample: .hydrogen, mode: .emission, sweep: 0.584)),
      SpectraPreset(
        key: "sunburn", name: "Sunburn", detail: "UV-B \u{00B7} 300 nm",
        note: "UV-B reaches the ground and is absorbed in DNA's 260 nm band, where neighboring thymines can fuse.",
        sources: one(WaveSource(lambda: 300e-9)), instrument: .bench, benchFocus: .dna),
      SpectraPreset(
        key: "xray", name: "Hand X-ray", detail: "60 keV \u{00B7} 20.7 pm",
        note: "Calcium-rich bone absorbs far more than soft tissue at this energy, and that difference is the image.",
        sources: one(WaveSource(lambda: Spectrum.wavelength(eV: 60e3))), instrument: .bench, benchFocus: .hand),
      SpectraPreset(
        key: "cmb", name: "Cosmic background", detail: "2.725 K \u{00B7} peak 1.06 mm",
        note: "The Big Bang's afterglow, cooled to 2.725 K and stretched into the microwave band.",
        sources: one(WaveSource(kind: .thermal, lambda: Wave.wienPeak(2.725), e0: 1e-3, temperature: 2.725)),
        instrument: .tuner),
      SpectraPreset(
        key: "nmr", name: "NMR", detail: "400 MHz in 9.4 T",
        note: "Protons in a strong magnet precess at a radio frequency. Their neighbors shift and split the lines.",
        sources: one(WaveSource(lambda: SI.c / 400.23e6)), instrument: .lab,
        lab: LabPatch(sample: .nmr, mode: .nmr400, sweep: 0.169)),
      SpectraPreset(
        key: "circular", name: "Circular light", detail: "Ex, Ey a quarter cycle apart",
        note: "Two equal components 90\u{00B0} apart sum to a field that turns in a circle, as in 3D cinema glasses. A polarizer at any angle passes 50%.",
        sources: one(WaveSource(lambda: 550e-9, theta: 45, delta: 90)), instrument: .decompose,
        decompose: DecomposePatch(tab: .polarization)),
      SpectraPreset(
        key: "laser", name: "Petawatt laser", detail: "800 nm \u{00B7} a\u{2080} = 2",
        note: "At this strength the magnetic force matters: a free electron traces a figure eight while its average drift carries it forward at half the speed of light.",
        sources: one(WaveSource(lambda: 800e-9, e0: 8.03e12)), instrument: .decompose,
        decompose: DecomposePatch(tab: .probe, a0: 2, probeMode: .both)),
      SpectraPreset(
        key: "greenhouse", name: "Greenhouse gas", detail: "CO\u{2082} \u{00B7} 15 \u{00B5}m bend",
        note: "CO\u{2082}'s 667 cm\u{207B}\u{00B9} bend (15 \u{00B5}m) absorbs part of the infrared the warm Earth radiates.",
        sources: one(WaveSource(lambda: 1 / (667.4 * 100))), instrument: .lab,
        lab: LabPatch(sample: .co2, mode: .ir, sweep: 0.926)),
    ]
  }
}

nonisolated extension SpectraState {
  /// JS `applyPreset`: medium (vacuum unless the preset sets one), Link off, A active, the
  /// preset's sources sanitized (with `logRange`), its instrument, and its bench / decompose /
  /// lab patches merged over the current settings (`lab.sweeping` off when the lab is patched).
  mutating func apply(_ p: SpectraPreset) {
    medium = p.medium ?? .vacuum
    link = false
    active = 0
    sources = p.sources
    instrument = p.instrument
    sanitizeSources()
    if let d = p.decompose {
      decompose.tab = d.tab
      if let a0 = d.a0 { decompose.a0 = a0 }
      if let mode = d.probeMode { decompose.probeMode = mode }
    }
    if let l = p.lab {
      lab.sweeping = false
      lab.sample = l.sample
      lab.mode = l.mode
      lab.sweep = l.sweep
    }
    if let focus = p.benchFocus { bench.focus = focus }
    preset = p.key
  }

  /// Applies the preset with this key; an unknown key leaves the state untouched and returns false.
  @discardableResult
  mutating func apply(preset key: String) -> Bool {
    guard let p = SpectraPreset.named(key) else { return false }
    apply(p)
    return true
  }
}
