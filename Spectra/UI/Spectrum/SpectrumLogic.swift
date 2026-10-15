import Foundation
import simd

// Pure, nonisolated logic of the Spectrum tab (Foundation + simd, Core and Phase only), kept
// apart from the views so `SpectrumLogicChecks` can run it on macOS without a simulator:
// persisted settings, the tuner window, the Earth-field axis, the phase-space request builder
// and the Φ-cube point extraction.

nonisolated extension OrbitCamera {
  /// Wave scope framing: a three-quarter side view of the beam (spectra-lab's yaw 64°, pitch 18°).
  static let waveScopeHome = OrbitCamera(yaw: -24, pitch: 16, distance: 6.4, target: SIMD3(0.28, 0, 0))
  /// Φ cube framing: three-quarter view with time across, frequency up and space in depth.
  static let wignerCubeHome = OrbitCamera(yaw: 32, pitch: 20, distance: 5.6)
}

/// Native settings that `SpectraState` (the web prototype's state) has no field for. Persisted
/// next to it under `Spectra.spectrum.v1`.
nonisolated struct SpectrumExtras: Codable, Equatable, Sendable {
  /// Wave scope camera.
  var camera = OrbitCamera.waveScopeHome
  /// Spectrum tuner visible window, log₁₀ λ (m). The web range is the default.
  var tunerLow = Spectrum.logMin
  var tunerHigh = Spectrum.logMax
  /// Decompose shows its fourth tab, Phase space (the Core tab enum has three).
  var phasePage = false
  /// Spectroscopy lab: the NMR sample's "Earth field (live |B|)" mode.
  var labEarth = false
  /// Earth-field mode cursor (fraction of the frequency axis).
  var earthSweep = 0.46
  var phase = PhaseSpaceSettings()

  init() {}

  init(from decoder: any Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    camera = (try? c.decodeIfPresent(OrbitCamera.self, forKey: .camera)) ?? camera
    tunerLow = (try? c.decodeIfPresent(Double.self, forKey: .tunerLow)) ?? tunerLow
    tunerHigh = (try? c.decodeIfPresent(Double.self, forKey: .tunerHigh)) ?? tunerHigh
    phasePage = (try? c.decodeIfPresent(Bool.self, forKey: .phasePage)) ?? phasePage
    labEarth = (try? c.decodeIfPresent(Bool.self, forKey: .labEarth)) ?? labEarth
    earthSweep = (try? c.decodeIfPresent(Double.self, forKey: .earthSweep)) ?? earthSweep
    phase = (try? c.decodeIfPresent(PhaseSpaceSettings.self, forKey: .phase)) ?? phase
    let span = TunerWindow.clamp(low: tunerLow, high: tunerHigh)
    tunerLow = span.lowerBound
    tunerHigh = span.upperBound
    if !earthSweep.isFinite { earthSweep = 0.46 }
    earthSweep = min(1, max(0, earthSweep))
  }
}

/// Decompose → Phase space settings (Utkarsh's spacetime Wigner view).
nonisolated struct PhaseSpaceSettings: Codable, Equatable, Sendable {
  /// Which dispersion relation the packets propagate on.
  enum DispersionChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The Spectrum medium (vacuum, air, water, glass, silica, diamond).
    case medium
    /// Cold plasma ω² = ω_p² + c²k² (the ionosphere).
    case plasma
    /// Hollow waveguide ω² = ω_c² + c²k².
    case waveguide
    var id: String { rawValue }
    var title: String {
      switch self {
      case .medium: "Medium"
      case .plasma: "Plasma"
      case .waveguide: "Waveguide"
      }
    }
  }

  var dispersion = DispersionChoice.medium
  /// Plasma frequency as a fraction of the reference frequency.
  var plasmaRatio = 0.6
  /// Waveguide cut-off as a fraction of the reference frequency.
  var cutoffRatio = 0.6
  /// Spatial chirp β of sources A, B, C (rad per λ_ref²).
  var chirp: [Double] = [0, 0, 0]
  /// Distance between neighbouring packets, in reference wavelengths.
  var spacing = 4.0
  /// The cube shows one k column instead of the k-integrated temporal Wigner.
  var kSlice = false
  /// Position of the k column along the k axis (0…1).
  var kFraction = 0.5
  /// Fixed-t slice (0…1 along t) and fixed-x slice (0…1 along x).
  var tFraction = 0.5
  var xFraction = 0.5
  var camera = OrbitCamera.wignerCubeHome

  static let chirpRange: ClosedRange<Double> = -0.4...0.4
  static let spacingRange: ClosedRange<Double> = 0...8
  static let ratioRange: ClosedRange<Double> = 0.05...0.95

  init() {}

  init(from decoder: any Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    dispersion = (try? c.decodeIfPresent(DispersionChoice.self, forKey: .dispersion)) ?? dispersion
    plasmaRatio = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .plasmaRatio)) ?? plasmaRatio, Self.ratioRange, 0.6)
    cutoffRatio = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .cutoffRatio)) ?? cutoffRatio, Self.ratioRange, 0.6)
    if let list = try? c.decodeIfPresent([Double].self, forKey: .chirp), list.count == 3 {
      chirp = list.map { Self.clamp($0, Self.chirpRange, 0) }
    }
    spacing = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .spacing)) ?? spacing, Self.spacingRange, 4)
    kSlice = (try? c.decodeIfPresent(Bool.self, forKey: .kSlice)) ?? kSlice
    kFraction = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .kFraction)) ?? kFraction, 0...1, 0.5)
    tFraction = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .tFraction)) ?? tFraction, 0...1, 0.5)
    xFraction = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .xFraction)) ?? xFraction, 0...1, 0.5)
    camera = (try? c.decodeIfPresent(OrbitCamera.self, forKey: .camera)) ?? camera
  }

  private static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
    v.isFinite ? min(r.upperBound, max(r.lowerBound, v)) : fallback
  }
}

/// The tuner's visible window: at least two decades inside the ruler range.
nonisolated enum TunerWindow {
  static let minimumSpan = 2.0
  static let web: ClosedRange<Double> = Spectrum.logRange
  static let full: ClosedRange<Double> = Spectrum.rulerLogRange

  /// A legal window from two edges.
  static func clamp(low: Double, high: Double) -> ClosedRange<Double> {
    guard low.isFinite, high.isFinite else { return web }
    var lo = min(low, high)
    var hi = max(low, high)
    if hi - lo < minimumSpan {
      let mid = (lo + hi) / 2
      lo = mid - minimumSpan / 2
      hi = mid + minimumSpan / 2
    }
    let span = min(hi - lo, full.upperBound - full.lowerBound)
    if lo < full.lowerBound {
      lo = full.lowerBound
      hi = lo + span
    }
    if hi > full.upperBound {
      hi = full.upperBound
      lo = hi - span
    }
    return lo...hi
  }

  /// `window` zoomed by `factor` (> 1 zooms in) about log₁₀ λ `anchor`.
  static func zoomed(_ window: ClosedRange<Double>, factor: Double, anchor: Double) -> ClosedRange<Double> {
    guard factor.isFinite, factor > 0 else { return window }
    let a = min(window.upperBound, max(window.lowerBound, anchor))
    let lo = a - (a - window.lowerBound) / factor
    let hi = a + (window.upperBound - a) / factor
    return clamp(low: lo, high: hi)
  }

  /// The smallest shift of `window` that puts `lg` inside it with `margin` decades to spare.
  static func following(_ window: ClosedRange<Double>, lg: Double, margin: Double = 0.4) -> ClosedRange<Double> {
    guard lg.isFinite else { return window }
    let span = window.upperBound - window.lowerBound
    if lg < window.lowerBound + margin {
      return clamp(low: lg - margin, high: lg - margin + span)
    }
    if lg > window.upperBound - margin {
      return clamp(low: lg + margin - span, high: lg + margin)
    }
    return window
  }
}

/// Everything persisted under `Spectra.spectrum.v1`. Decoding is lenient: a bad field keeps
/// its default instead of discarding the rest.
nonisolated struct SpectrumSaved: Codable, Sendable {
  var state: SpectraState
  var extras: SpectrumExtras

  init(state: SpectraState, extras: SpectrumExtras) {
    self.state = state
    self.extras = extras
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    state = (try? c.decodeIfPresent(SpectraState.self, forKey: .state)) ?? SpectraState()
    extras = (try? c.decodeIfPresent(SpectrumExtras.self, forKey: .extras)) ?? SpectrumExtras()
  }
}

/// The Earth-field lab mode's frequency axis: 500 Hz to 4 kHz, which holds the water-proton
/// line for any field on Earth (25–65 µT → 1.06–2.77 kHz).
nonisolated enum EarthFieldAxis {
  static let from = 500.0
  static let to = 4000.0
  /// Half-width the line is drawn with: about one point of a phone-width plot (the real line
  /// is about 1 Hz wide, far narrower than a pixel of this axis).
  static let displayHalfWidth = 12.0
  /// Earth's surface field runs from about 25 µT (South Atlantic) to 65 µT (magnetic poles).
  static let fieldRange: ClosedRange<Double> = 25...65

  /// Frequency at axis fraction u.
  static func frequency(at u: Double) -> Double { from + (to - from) * min(1, max(0, u)) }
  /// Axis fraction of a frequency.
  static func fraction(of f: Double) -> Double { (f - from) / (to - from) }
  /// The EM wavelength the cursor probes, c/f.
  static func lambda(at u: Double) -> Double { Spectrum.wavelength(frequency: frequency(at: u)) }
}

/// Turns the Spectrum sources and the Phase space settings into a `Phase.PhaseSpaceRequest`
/// (API-phase.md, "spectrum-ui" usage). Sources A/B/C become 1+1-D Gaussian packets in display
/// units of the reference source; a plane wave is drawn as a long packet
/// (`planeWaveCycles`) and thermal light is left out (it is incoherent).
nonisolated enum PhaseSpaceRequestBuilder {
  /// Grid size nx = nt (and the lag bins). 48 meets the iPhone budget in a Release build; the
  /// unoptimized Debug build uses 40, the smallest grid on which two default pulses 4 λ apart
  /// read CONSISTENT (alias < 10⁻³; 32 reads ALIASED).
  static let gridSize: Int = {
    #if DEBUG
      40
    #else
      48
    #endif
  }()

  /// Cycles of the packet that stands in for a plane wave. Core allows 12, but a 12-cycle
  /// packet overflows the 48-point window (ALIASED in every medium); 10 cycles is the longest
  /// that reads CONSISTENT there.
  static let planeWaveCycles = 10.0

  struct Built: Sendable, Hashable {
    var request: Phase.PhaseSpaceRequest
    /// Plain sentences about how the sources were mapped.
    var notes: [String]
    /// Source index of each packet, in packet order.
    var sources: [Int]
    /// The reference source's vacuum wavelength (axis unit), m.
    var referenceLambda: Double
  }

  static func dispersion(state: SpectraState, settings: PhaseSpaceSettings) -> Phase.Dispersion {
    let nuRef = Spectrum.frequency(state.referenceSource.lambda)
    switch settings.dispersion {
    case .medium: return state.medium == .vacuum ? .vacuum : .medium(state.medium)
    case .plasma: return .plasma(plasmaFrequency: settings.plasmaRatio * nuRef)
    case .waveguide: return .waveguide(cutoffFrequency: settings.cutoffRatio * nuRef)
    }
  }

  static func build(state: SpectraState, settings: PhaseSpaceSettings) -> Built {
    let ref = state.referenceSource
    let nuRef = Spectrum.frequency(ref.lambda)
    let disp = dispersion(state: state, settings: settings)
    let model = Phase.ShellModel(disp, units: Phase.DisplayUnits(referenceFrequency: nuRef))
    var notes: [String] = []
    var packets: [Phase.GaussianPacket] = []
    var used: [Int] = []
    let coherent = state.enabledIndices.filter { state.sources[$0].kind != .thermal }
    for i in state.enabledIndices where state.sources[i].kind == .thermal {
      notes.append(
        "Source \(SpectraState.sourceNames[i]) is thermal light: its phases are random, so it has no single Wigner picture and is left out.")
    }
    for (slot, i) in coherent.enumerated() {
      let s = state.sources[i]
      let letter = SpectraState.sourceNames[i]
      let cycles = s.kind == .plane ? planeWaveCycles : s.cycles
      if s.kind == .plane {
        notes.append("Source \(letter) is a plane wave; it is shown as a long (\(Int(planeWaveCycles))-cycle) packet.")
      }
      let center = (Double(slot) - Double(coherent.count - 1) / 2) * settings.spacing
      let chirp = settings.chirp.indices.contains(i) ? settings.chirp[i] : 0
      guard
        let p = Phase.GaussianPacket.fromSource(
          lambda: s.lambda, cycles: cycles, model: model, chirp: chirp, center: center)
      else {
        notes.append("Source \(letter) is below cut-off in \(disp.title.lowercased()): no wave propagates.")
        continue
      }
      packets.append(p)
      used.append(i)
    }
    let request = Phase.PhaseSpaceRequest(
      packets: packets, dispersion: disp, referenceFrequency: nuRef, gridSize: gridSize, keepFull: settings.kSlice)
    return Built(request: request, notes: notes, sources: used, referenceLambda: ref.lambda)
  }
}

/// Everything the Probe charge drawing needs that does not change from frame to frame: the
/// exact trajectory (Core), each point's sideways position along the polarization direction,
/// the extents, and the drift-frame inset. Built once per (a₀, force mode, θ, δ) and cached by
/// the model, so a frame only strokes paths and moves the electron.
nonisolated struct ProbeGeometry: Sendable {
  var points: [Wave.TrajectoryPoint] = []
  /// Sideways position of each point along the polarization direction (`SpectrumDisplay.transverse`).
  var transverse: [Double] = []
  /// Largest forward distance and largest |sideways| distance (both ≥ 1e-9).
  var zMax = 1e-9
  var tMax = 1e-9
  /// The drift-frame inset (E + v×B only, else empty): each point's (forward, sideways)
  /// position riding with the drift, centred and scaled to −1…1 on each axis.
  var inset: [SIMD2<Double>] = []
  /// Half-ranges of the inset before scaling, (forward, sideways).
  var insetHalf = SIMD2<Double>(1, 1)

  init() {}

  init(_ traj: [Wave.TrajectoryPoint], thetaDeg: Double, mode: Wave.ProbeMode) {
    guard !traj.isEmpty else { return }
    points = traj
    transverse = traj.map { SpectrumDisplay.transverse($0, thetaDeg: thetaDeg) }
    zMax = max(1e-9, traj.map(\.z).max() ?? 0)
    tMax = max(1e-9, transverse.map(abs).max() ?? 0)
    guard mode == .both else { return }
    // Core's drift frame removes the forward drift. Unless E is linear and starts at a field
    // maximum, the electron (at rest at η = 0) also keeps a steady sideways drift −A(0),
    // linear in η; remove it too so the inset rides with the whole drift and shows a closed
    // orbit (the figure eight for linear light) instead of a zigzag.
    let raw = SpectrumDisplay.driftFrame(traj, thetaDeg: thetaDeg)
    let eta0 = traj[0].eta, span = traj[traj.count - 1].eta - eta0
    let side = span > 0 ? (raw[raw.count - 1].y - raw[0].y) / span : 0
    let pts = zip(raw, traj).map { p, q in SIMD2(p.x, p.y - side * (q.eta - eta0)) }
    // Centred: starting from rest, the sideways swing is one-sided (0…2a).
    let lo = pts.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
    let hi = pts.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
    let mid = (lo + hi) / 2
    let half = simd_max((hi - lo) / 2, SIMD2(repeating: 1e-12))
    insetHalf = half
    inset = pts.map { ($0 - mid) / half }
  }
}

/// The Fourier page's frequency stems: every component of every source on screen (Core's
/// `Wave.components`), their largest amplitude and the log-frequency axis that spans them.
nonisolated struct FourierStems: Sendable {
  struct Stem: Sendable {
    var lambda: Double
    var logF: Double
    var a: Double
  }
  var stems: [Stem]
  var maxA: Double
  var axis: ClosedRange<Double>?
}

/// Points of the Φ cube for the Metal volume: cube coordinates −1…1 (x = space, y = time,
/// z = frequency) and the signed value w in −1…1.
nonisolated enum WignerCubePoints {
  /// The strongest cells of `cube` (axes x, t, ν), at most `budget` of them and none below 4 %
  /// of the peak. `peak` normalizes by another magnitude (a k column by the whole Φ, so a
  /// column far from the packets stays dark instead of showing its own amplified ripple);
  /// nil normalizes by the cube's own max |value|.
  static func extract(_ cube: Phase.Cube, budget: Int = 12_000, peak: Double? = nil) -> [SIMD4<Float>] {
    let values: [Float]
    if let peak, peak.isFinite, peak > 0 {
      values = cube.values.map { v in v.isFinite ? Float(max(-1, min(1, v / peak))) : 0 }
    } else {
      values = cube.signedUnit()
    }
    let na = cube.axisA.count, nb = cube.axisB.count, nc = cube.axisC.count
    guard na > 1, nb > 1, nc > 1, values.count == na * nb * nc else { return [] }
    // Threshold from a histogram of |w| so the count stays inside the budget.
    var histogram = [Int](repeating: 0, count: 100)
    for v in values {
      let a = abs(v)
      histogram[min(99, Int(a * 100))] += 1
    }
    var threshold: Float = 0.04
    var running = 0
    for bin in stride(from: 99, through: 0, by: -1) {
      running += histogram[bin]
      if running > budget {
        threshold = max(threshold, Float(bin + 1) / 100)
        break
      }
    }
    var out: [SIMD4<Float>] = []
    out.reserveCapacity(min(budget, values.count))
    let sa = 2 / Float(na - 1), sb = 2 / Float(nb - 1), sc = 2 / Float(nc - 1)
    for a in 0..<na {
      for b in 0..<nb {
        let base = (a * nb + b) * nc
        for c in 0..<nc {
          let v = values[base + c]
          guard abs(v) >= threshold else { continue }
          out.append(SIMD4(Float(a) * sa - 1, Float(b) * sb - 1, Float(c) * sc - 1, v))
        }
      }
    }
    return out
  }
}
