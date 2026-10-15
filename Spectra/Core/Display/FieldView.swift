import Foundation

/// Display-space fields for the Wave scope, Decompose and Fourier views (port of spectra-lab
/// `ui/fieldview.js`; parity-tested in the `fieldview` category). UI-framework-free.
///
/// Distances are in units of the **reference wavelength** (the first enabled source, in vacuum)
/// and time is screen time; every source keeps its true frequency ratio `r = λ_ref/λ` to the
/// reference. The medium fills `z > 0` only.
///
/// The JS keeps a module-level cache keyed on `(sources, medium)`. Here `DisplaySources` is a
/// plain value: hold one and rebuild it when `isCurrent(sources:medium:)` turns false.
nonisolated enum FieldView {
  /// Components more than 24× finer or coarser than the reference are not drawn.
  static let maxRatio: Double = 24

  /// Source identity tags A, B, C (spectra-lab `THEME.sources`): phosphor, rose, ice.
  static let sourceTags: [String] = ["#66f58f", "#ff8fb8", "#8fd3ff"]

  /// Source letters by index.
  static let sourceLetters: [String] = ["A", "B", "C"]

  /// One drawable frequency component of a source.
  struct Component: Hashable, Sendable {
    /// Frequency ratio to the reference, λ_ref/λ.
    var r: Double
    /// Amplitude relative to the source's E₀ (1 for plane waves and pulses).
    var amp: Double
    /// Phase, radians.
    var phase: Double
    /// Real index in the medium (1 when the medium's formula is invalid there).
    var n: Double
    /// Extinction coefficient κ in the medium (0 when invalid).
    var k: Double
    /// Vacuum wavelength, m.
    var lambda: Double
  }

  /// One enabled source, ready to draw.
  struct DisplaySource: Hashable, Sendable {
    /// The source as configured.
    var source: WaveSource
    /// Index in `SpectraState.sources` (0 = A).
    var index: Int
    var jones: Wave.Jones
    /// Components within `maxRatio` of the reference.
    var comps: [Component]
    /// How many components were dropped by the `maxRatio` filter.
    var hidden: Int
    /// E₀ share of the enabled total (×0.45 for thermal light).
    var scale: Double
    /// `Spectrum.displayColorHex(λ)`.
    var colorHex: String
    /// Source identity colour (`sourceTags[index]`).
    var tag: String
  }

  /// Everything `fieldAt` needs, built once per `(sources, medium)`.
  struct DisplaySources: Hashable, Sendable {
    /// The reference source: the first enabled one, else A.
    var ref: WaveSource
    var list: [DisplaySource]
    var inMedium: Bool
    /// The inputs this value was built from (the JS cache key).
    var sources: [WaveSource]
    var medium: Matter.Medium

    /// True when this value still describes `sources` in `medium`.
    func isCurrent(sources: [WaveSource], medium: Matter.Medium) -> Bool {
      self.sources == sources && self.medium == medium
    }
  }

  /// The field at one point: E components (display units) and the medium index there.
  /// B is drawn as n ẑ × E in these units.
  struct FieldPoint: Hashable, Sendable {
    var ex: Double
    var ey: Double
    var n: Double
  }

  /// JS `displaySources(state)`.
  static func displaySources(_ state: SpectraState) -> DisplaySources {
    displaySources(sources: state.sources, medium: state.medium)
  }

  /// JS `displaySources` from the sources and the medium alone. Thermal sources expand into
  /// `components(s, 15)`; plane waves and pulses are one carrier (pulses get an analytic
  /// envelope in `fieldAt`). An invalid medium index counts as n = 1, κ = 0 here, while the
  /// readouts use the fallback n.
  static func displaySources(sources: [WaveSource], medium: Matter.Medium) -> DisplaySources {
    let enabled = sources.indices.filter { sources[$0].enabled }
    // `?? WaveSource()` only guards an empty list (SpectraState always holds three sources).
    let ref = enabled.first.map { sources[$0] } ?? sources.first ?? WaveSource()
    var total = 0.0
    for i in enabled { total = total + sources[i].e0 }
    // JS `reduce(...) || 1`: a zero (or NaN) total falls back to 1.
    let totalE0 = total == 0 || total.isNaN ? 1 : total
    let list = enabled.map { i -> DisplaySource in
      let s = sources[i]
      let raw: [Wave.Component] =
        s.kind == .thermal
        ? Wave.components(s, count: 15)
        : [Wave.Component(lambda: s.lambda, amp: 1, phase: (s.phi * Double.pi) / 180)]
      let comps = raw.map { c -> Component in
        let nk = medium == .vacuum ? Matter.MediumIndex(n: 1, k: 0, valid: true) : medium.index(c.lambda)
        return Component(
          r: ref.lambda / c.lambda, amp: c.amp, phase: c.phase, n: nk.valid ? nk.n : 1, k: nk.valid ? nk.k : 0,
          lambda: c.lambda)
      }
      let visible = comps.filter { $0.r <= maxRatio && $0.r >= 1 / maxRatio }
      return DisplaySource(
        source: s, index: i, jones: Wave.jones(s), comps: visible, hidden: comps.count - visible.count,
        scale: (s.e0 / totalE0) * (s.kind == .thermal ? 0.45 : 1), colorHex: Spectrum.displayColorHex(s.lambda),
        tag: i < sourceTags.count ? sourceTags[i] : sourceTags[sourceTags.count - 1])
    }
    return DisplaySources(ref: ref, list: list, inMedium: medium != .vacuum, sources: sources, medium: medium)
  }

  /// Total field at display position `z` (reference wavelengths) and screen time `t` (s), with
  /// display speed κ (`speed`, reference cycles per screen second). `only` restricts the sum to
  /// one source index. Inside the medium (z > 0) each component is scaled by the Fresnel
  /// transmission 2/(1 + n) and by exp(−2π·r·κ·z); `n` is the index of the last component
  /// evaluated there (1 outside).
  ///
  /// Precision: `t` grows without bound on the app clock. In Double this stays exact enough
  /// for hours; convert to Float only at the GPU boundary (port-plan §9.2).
  static func fieldAt(_ ds: DisplaySources, z: Double, t: Double, speed: Double, only: Int? = nil) -> FieldPoint {
    let tau = Wave.tau
    var ex = 0.0, ey = 0.0, nAt = 1.0
    let inside = ds.inMedium && z > 0
    for d in ds.list {
      if let only, d.index != only { continue }
      let j = d.jones
      for c in d.comps {
        let n = inside ? c.n : 1
        if inside { nAt = c.n }
        let q = tau * c.r * n * z - tau * c.r * speed * t + c.phase
        var a = d.scale * c.amp
        if inside { a *= (2 / (1 + c.n)) * exp(-tau * c.r * c.k * z) }
        if d.source.kind == .pulse {
          // The envelope rides with the carrier and repeats every few pulse lengths so it stays on screen.
          let period = tau * (d.source.cycles * 2.2 + 3)
          let centre =
            ((tau * c.r * speed * t).truncatingRemainder(dividingBy: period) + period)
            .truncatingRemainder(dividingBy: period) - period / 2
          a *= Wave.pulseEnvelope(d.source, phase: tau * c.r * (inside ? n : 1) * z - centre)
        }
        ex += a * j.ax * cos(q)
        ey += a * j.ay * cos(q + j.delta)
      }
    }
    return FieldPoint(ex: ex, ey: ey, n: nAt)
  }

  /// "Source A, B is too far from the reference wavelength to draw at this zoom", or "" when
  /// every enabled source has all its components on screen.
  static func hiddenNote(_ ds: DisplaySources) -> String {
    let names = ds.list.filter { $0.hidden > 0 || $0.comps.isEmpty }.map { d in
      d.index < sourceLetters.count ? sourceLetters[d.index] : "?"
    }
    return names.isEmpty
      ? "" : "Source \(names.joined(separator: ", ")) is too far from the reference wavelength to draw at this zoom"
  }
}
