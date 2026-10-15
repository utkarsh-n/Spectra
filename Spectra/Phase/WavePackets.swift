import Foundation
import simd

// 1+1-D Gaussian wave packets on a dispersion shell (convention C), their closed-form Wigner
// distributions (the analytic oracle), and the one-call phase-space scene for the UI.

nonisolated extension Phase {
  /// A chirped Gaussian packet, specified at t = 0:
  ///
  ///     ψ(x, 0) = A e^{iφ} (2πσ²)^{−1/4} exp(−u²/(4σ²) + iβu² + ik₀u),  u = x − x₀
  ///
  /// with k₀ = ±k(ν₀) on the shell, and propagated spectrally: ψ(x, t) = ∫ ψ̃(k) e^{i(kx − ω(k)t)} dk/2π.
  /// ∫|ψ(x, 0)|² dx = A². Units are those of the `ShellModel` (SI, or display units: x in
  /// λ_ref, t in T_ref, ν in ν_ref).
  struct GaussianPacket: Sendable, Hashable, Codable {
    /// Carrier frequency ν₀ (on the positive-frequency branch).
    var carrierFrequency: Double
    /// rms width σ of |ψ(x, 0)|².
    var width: Double
    /// Spatial chirp β (rad per length²): phase β(x − x₀)².
    var chirp: Double
    /// Centre x₀ at t = 0.
    var center: Double
    /// +1 moves toward +x (k₀ > 0), −1 toward −x.
    var direction: Int
    var amplitude: Double
    var phase: Double

    init(
      carrierFrequency: Double, width: Double, chirp: Double = 0, center: Double = 0, direction: Int = 1,
      amplitude: Double = 1, phase: Double = 0
    ) {
      self.carrierFrequency = carrierFrequency
      self.width = width
      self.chirp = chirp
      self.center = center
      self.direction = direction
      self.amplitude = amplitude
      self.phase = phase
    }

    /// A packet from a Spectra source: carrier λ (vacuum, m) and pulse length in carrier cycles
    /// at intensity FWHM (Core's `WaveSource.cycles`), in display units of `model`. The spatial
    /// width is the group velocity × the pulse duration (σ_t = cycles·T/(2√(2 ln 2))).
    static func fromSource(
      lambda: Double, cycles: Double, model: ShellModel, chirp: Double = 0, center: Double = 0, direction: Int = 1,
      amplitude: Double = 1
    ) -> GaussianPacket? {
      guard lambda.isFinite, lambda > 0 else { return nil }
      let nuHz = SI.c / lambda
      let nu = model.units.map { $0.frequency(nuHz) } ?? nuHz
      guard let vg = model.groupVelocity(nu), vg.isFinite, vg > 0 else { return nil }
      let sigmaT = max(0.5, cycles) / nu / (2 * (2 * log(2.0)).squareRoot())
      return GaussianPacket(
        carrierFrequency: nu, width: vg * sigmaT, chirp: chirp, center: center, direction: direction, amplitude: amplitude)
    }

    /// k₀ on the shell (signed by `direction`); nil below cut-off.
    func carrierWavenumber(_ model: ShellModel) -> Double? {
      model.wavenumber(carrierFrequency).flatMap { $0.isFinite ? (direction >= 0 ? $0 : -$0) : nil }
    }

    /// True when every parameter is finite and the width is positive (a packet that can be
    /// sampled; `packetField` and the scene leave invalid packets out instead of trapping).
    var isWellFormed: Bool {
      carrierFrequency.isFinite && width.isFinite && width > 0 && chirp.isFinite && center.isFinite && amplitude.isFinite
        && phase.isFinite && spectralWidth.isFinite
    }

    /// rms width of |ψ̃(k)|²: σ_k² = 1/(4σ²) + 4β²σ².
    var spectralWidth: Double { (1 / (4 * width * width) + 4 * chirp * chirp * width * width).squareRoot() }

    /// ψ̃(k) at t = 0 (∫ψ e^{−ikx} dx) for carrier k₀.
    func spectrum(k: Double, k0: Double) -> SIMD2<Double> {
      let s2 = width * width
      let norm = amplitude * pow(2 * Double.pi * s2, -0.25)
      // a = 1/(4σ²) − iβ; √(π/a) e^{−(k−k₀)²/(4a)}.
      let ar = 1 / (4 * s2)
      let ai = -chirp
      let mod2 = ar * ar + ai * ai
      // 1/a
      let ir = ar / mod2
      let ii = -ai / mod2
      // √(π/a) = √π · √(1/a) (principal root)
      let rmod = (ir * ir + ii * ii).squareRoot()
      let sr = ((rmod + ir) / 2).squareRoot()
      let si = (ii >= 0 ? 1.0 : -1.0) * ((rmod - ir) / 2).squareRoot()
      let d = k - k0
      // exponent −d²/(4a) = −(d²/4)(1/a)
      let er = -d * d / 4 * ir
      let ei = -d * d / 4 * ii - k * center + phase
      let mag = norm * Double.pi.squareRoot() * exp(er)
      let cr = mag * cos(ei)
      let ci = mag * sin(ei)
      return SIMD2(cr * sr - ci * si, cr * si + ci * sr)
    }

    /// ψ(x, 0).
    func initialField(x: Double, k0: Double) -> SIMD2<Double> {
      let u = x - center
      let norm = amplitude * pow(2 * Double.pi * width * width, -0.25)
      let env = norm * exp(-u * u / (4 * width * width))
      let ph = chirp * u * u + k0 * u + phase
      return SIMD2(env * cos(ph), env * sin(ph))
    }

    /// Closed-form spatial Wigner W(x, k; t) = W₀(x − (v_g + D(k − k₀)) t, k) for a Taylor
    /// (linear or quadratic) dispersion around k₀ — exact, because the Wigner of a field under a
    /// quadratic ω(k) is transported along straight rays. W₀ = 2A² exp(−u²/(2σ²) − 2σ²(k − k₀ − 2βu)²).
    func closedFormSpatialWigner(x: Double, k: Double, t: Double, taylor: Dispersion.Taylor) -> Double {
      let v = taylor.groupVelocity + taylor.gvd * (k - taylor.k0)
      let u = x - v * t - center
      let s2 = width * width
      let q = k - taylor.k0 - 2 * chirp * u
      return 2 * amplitude * amplitude * exp(-u * u / (2 * s2) - 2 * s2 * q * q)
    }

    /// Closed-form temporal Wigner W(t, ν; x) at fixed x for a linear dispersion (D = 0,
    /// v_g ≠ 0): W = W₀(x − v_g t, (2πν − Ω)/v_g)/|v_g| with Ω = ω₀ − v_g k₀ (nil for D ≠ 0).
    func closedFormTemporalWigner(t: Double, nu: Double, x: Double, taylor: Dispersion.Taylor) -> Double? {
      guard taylor.gvd == 0, taylor.groupVelocity != 0 else { return nil }
      let v = taylor.groupVelocity
      let omegaOffset = taylor.omega0 - v * taylor.k0
      let k = (2 * Double.pi * nu - omegaOffset) / v
      let u = x - v * t - center
      let s2 = width * width
      let q = k - taylor.k0 - 2 * chirp * u
      return 2 * amplitude * amplitude * exp(-u * u / (2 * s2) - 2 * s2 * q * q) / abs(v)
    }
  }

  /// An observation window in time applied to the field amplitude, so the Φ cube fades at the
  /// window edges instead of being cut (a hard cut leaks across the band and shows as ALIASED).
  enum TimeGate: Sendable, Hashable, Codable {
    /// e^{−(t − t_c)²/(4σ²)} (|ψ|² has rms duration σ).
    case gaussian(center: Double, sigma: Double)
    /// Raised cosine sin²(π(t − start)/(end − start)) on [start, end], 0 outside.
    case hann(start: Double, end: Double)

    func amplitude(_ t: Double) -> Double {
      switch self {
      case .gaussian(let c, let s):
        return exp(-(t - c) * (t - c) / (4 * s * s))
      case .hann(let a, let b):
        guard b > a, t > a, t < b else { return 0 }
        let v = sin(Double.pi * (t - a) / (b - a))
        return v * v
      }
    }

    /// Hann gate spanning a time axis with one empty step beyond each end.
    static func hann(over t: Axis) -> TimeGate { .hann(start: t.start - t.step, end: t.end + t.step) }
  }

  /// Result of `packetField`: the field and how much spectral energy had no propagating mode
  /// (below cut-off or outside the model).
  struct PacketField: Sendable, Hashable {
    var field: Field
    var droppedFraction: Double
    /// k₀ of each packet (nil below cut-off, or for a packet with a non-finite or non-positive
    /// parameter, which is left out).
    var carriers: [Double?]
    /// True when the internal k grid hit its size cap (`maxInternalPoints`): a packet far wider
    /// than the window (or a huge chirp) then wraps around its period and the field is approximate.
    var periodLimited: Bool = false
  }

  /// Largest internal spectral grid of `packetField` (2²¹ points, 16 MB per array).
  static let maxInternalPoints = 1 << 21
  /// Largest `PhaseSpaceRequest.gridSize` (points per axis) the scene uses.
  static let maxSceneGrid = 128

  /// Superposition of packets (Spectra sources A/B/C) propagated through `model`, sampled on
  /// x × t. Each k mode gets e^{−iω(k)t} with ω ≥ 0 (a positive-frequency field, so its Φ sits on
  /// the ν > 0 shell). The k integral is a Riemann sum on an internal grid that resolves every
  /// packet's spectrum (±10σ_k) and repeats in x far beyond the packets' reach over the time
  /// axis, so the result does not depend on the output grid (one x sample works too).
  static func packetField(
    _ packets: [GaussianPacket], model: ShellModel, x: Axis, t: Axis, gate: TimeGate? = nil
  ) -> PacketField {
    let nx = x.count
    let nt = t.count
    var re = [Double](repeating: 0, count: nx * nt)
    var im = re
    let carriers = packets.map { $0.isWellFormed ? $0.carrierWavenumber(model) : nil }
    let axesOK = x.start.isFinite && x.step.isFinite && t.start.isFinite && t.step.isFinite
    guard nx > 0, nt > 0, axesOK, carriers.contains(where: { $0 != nil }) else {
      return PacketField(field: Field(re: re, im: im, x: x, t: t), droppedFraction: carriers.isEmpty ? 0 : 1, carriers: carriers)
    }
    // Spectral reach and spatial extent over the time axis.
    let xc = x.start + Double(nx - 1) / 2 * x.step
    let tAbs = max(abs(t.start), abs(t.end))
    let step = abs(x.step) > 0 ? abs(x.step) : 1
    var kReach = 0.0
    var extent = 0.0
    // A packet whose envelope stays more than 12σ(t) outside the x window for every t of the
    // axis contributes nothing (< 1e-15 of its amplitude). It is left out of the sum rather than
    // stretching the internal grid until the period wraps it back in as noise.
    var active = carriers
    for (j, (p, k0)) in zip(packets, carriers).enumerated() {
      guard let k0 else { continue }
      let sk = p.spectralWidth
      let tay = model.taylor(atFrequency: p.carrierFrequency, direction: p.direction)
      let v = abs(tay?.groupVelocity ?? 1)
      let d = abs(tay?.gvd ?? 0)
      let reach = v * tAbs + 12 * (p.width + d * sk * tAbs)
      let gap = abs(p.center - xc) - Double(nx) * step / 2 - reach
      if !(gap <= 0) && reach.isFinite {
        active[j] = nil
        continue
      }
      kReach = max(kReach, abs(k0) + 10 * sk)
      let e = abs(p.center - xc) + reach
      if e.isFinite { extent = max(extent, e) }
    }
    guard active.contains(where: { $0 != nil }) else {
      return PacketField(field: Field(re: re, im: im, x: x, t: t), droppedFraction: 0, carriers: carriers)
    }
    // Internal grid: Δξ = Δx/r resolves ±k_reach, period q·Δξ ≥ 2(extent + window). Both are
    // capped (`maxInternalPoints`) so a degenerate packet cannot allocate without bound.
    let cap = Double(maxInternalPoints)
    let rD = (step * kReach / Double.pi * 1.05).rounded(.up)
    let r = Int(min(max(1, rD.isFinite ? rD : 1), max(1, (cap / Double(8 * nx)).rounded(.down))))
    let dxi = step / Double(r)
    let window = Double(nx) * step
    let neededD = (2 * (extent + window) / dxi).rounded(.up) + 1
    let needed = Int(min(neededD.isFinite ? neededD : cap, cap))
    var q = DFT.goodSize(atLeast: min(max(8 * nx * r, needed, 64), maxInternalPoints))
    q = max(q, DFT.goodSize(atLeast: (nx - 1) * r + 1))
    let periodLimited = !(rD.isFinite && Double(r) >= rD) || !(neededD.isFinite && neededD <= Double(q))
    let dk = 2 * Double.pi / (Double(q) * dxi)
    let sign: Double = x.step >= 0 ? 1 : -1
    var specRe = [Double](repeating: 0, count: q)
    var specIm = specRe
    var omega = [Double?](repeating: nil, count: q)
    var total = 0.0
    var dropped = 0.0
    for b in 0..<q {
      let s = b < (q + 1) / 2 ? b : b - q
      let k = sign * Double(s) * dk
      var acc = SIMD2<Double>(0, 0)
      for (p, k0) in zip(packets, active) {
        guard let k0 else { continue }
        acc += p.spectrum(k: k, k0: k0)
      }
      // e^{ik x_start} so index i·r of the inverse DFT is x_start + iΔx.
      let c = cos(k * x.start)
      let sn = sin(k * x.start)
      specRe[b] = acc.x * c - acc.y * sn
      specIm[b] = acc.x * sn + acc.y * c
      let pw = acc.x * acc.x + acc.y * acc.y
      total += pw
      omega[b] = model.omega(k)
      if omega[b] == nil {
        dropped += pw
        specRe[b] = 0
        specIm[b] = 0
      }
    }
    let dft = DFT(count: q)
    var inRe = [Double](repeating: 0, count: q)
    var inIm = inRe
    var outRe = inRe
    var outIm = inRe
    let scale = dk / (2 * Double.pi)
    for it in 0..<nt {
      let tt = t.value(it)
      for b in 0..<q {
        guard let w = omega[b] else {
          inRe[b] = 0
          inIm[b] = 0
          continue
        }
        let c = cos(w * tt)
        let sn = -sin(w * tt)
        inRe[b] = specRe[b] * c - specIm[b] * sn
        inIm[b] = specRe[b] * sn + specIm[b] * c
      }
      dft.execute(.positive, inputReal: inRe, inputImag: inIm, outputReal: &outRe, outputImag: &outIm)
      let g = gate?.amplitude(tt) ?? 1
      for ix in 0..<nx {
        re[ix * nt + it] = outRe[ix * r] * scale * g
        im[ix * nt + it] = outIm[ix * r] * scale * g
      }
    }
    return PacketField(
      field: Field(re: re, im: im, x: x, t: t), droppedFraction: total > 0 ? dropped / total : 0, carriers: carriers,
      periodLimited: periodLimited)
  }
}

// MARK: - The phase-space scene (Spectrum → Decompose → Phase space)

nonisolated extension Phase {
  struct PhaseSpaceRequest: Sendable, Hashable, Codable {
    /// Up to three packets (sources A/B/C) in display units of `referenceFrequency`. `center` is
    /// where the packet's envelope is at the middle of the time window.
    var packets: [GaussianPacket]
    var dispersion: Dispersion
    /// ν_ref (Hz): usually source A's c/λ. Axes are in λ_ref, T_ref, rad/λ_ref and ν_ref.
    var referenceFrequency: Double
    /// nx = nt (48 meets the live budget; clamped to 8…128, `maxSceneGrid`).
    var gridSize: Int = 48
    /// Lag DFT bins per axis (nil: the next vDSP size ≥ gridSize, the exact Φ).
    var lagBins: Int?
    /// Raised-cosine (Hann) observation window over the time axis, so the cube fades to zero at
    /// the window edges instead of leaking across the band.
    var observationWindow: Bool = true
    /// k̂ of the k-slice cube (nil: none; the k-integrated cube is always computed).
    var kSlice: Double?
    /// Keep the whole 4-D Φ (21 MB at 48⁴) for scrubbing the k slice without recomputing.
    var keepFull: Bool = false
    /// k band override (nil: positive when every packet moves toward +x, else centred).
    var kBand: Band?

    init(
      packets: [GaussianPacket], dispersion: Dispersion, referenceFrequency: Double, gridSize: Int = 48,
      lagBins: Int? = nil, observationWindow: Bool = true, kSlice: Double? = nil, keepFull: Bool = false,
      kBand: Band? = nil
    ) {
      self.kBand = kBand
      self.packets = packets
      self.dispersion = dispersion
      self.referenceFrequency = referenceFrequency
      self.gridSize = gridSize
      self.lagBins = lagBins
      self.observationWindow = observationWindow
      self.kSlice = kSlice
      self.keepFull = keepFull
    }
  }

  struct PhaseSpaceScene: Sendable, Hashable {
    var units: DisplayUnits
    var model: ShellModel
    var field: Field
    /// |ψ(x, t)|² (rows x, columns t).
    var intensity: Grid2D
    /// |ψ̃(k, ν)|² on the Wigner's (k, ν) columns, with the alias partners.
    var spectrum: FieldSpectrum
    var wigner: SpacetimeWigner
    var report: MarginalReport
    /// The medium's shell over the k axis (display units).
    var shell: [ShellPoint]
    /// (k̂₀, ν̂₀) of each packet (nil: below cut-off, the packet is not drawn).
    var carriers: [SIMD2<Double>?]
    /// Plain-language notes (cut-off, model validity, dropped energy).
    var notes: [String]
  }

  /// Builds the Phase space view in one call (pure; run it in `Task.detached`): picks a grid that
  /// satisfies rules 1–2 for the packets' band (k positive when every packet moves toward +x,
  /// otherwise centred; ν positive; 10 % margin), a time window during which the packets stay
  /// inside the x window, generates the field under a Hann observation window, and computes Φ
  /// with its marginal report.
  static func phaseSpaceScene(_ request: PhaseSpaceRequest) -> PhaseSpaceScene {
    let refOK = request.referenceFrequency.isFinite && request.referenceFrequency > 0
    let units = DisplayUnits(referenceFrequency: refOK ? request.referenceFrequency : 1)
    let model = ShellModel(request.dispersion, units: units)
    // 8…128 points per axis: Φ costs ∝ n⁴ (48 → ≈ 60 ms; 128 → seconds and 270 MB of cubes).
    let n = min(max(8, request.gridSize), maxSceneGrid)
    var notes: [String] = []
    if !refOK { notes.append("The reference frequency is not a positive number: no packet can be placed.") }
    var kMax = 0.0
    var nuMax = 0.0
    var vMax = 0.0
    var sigmaMax = 0.0
    var placed: [GaussianPacket] = []
    for (i, p) in request.packets.prefix(3).enumerated() where refOK {
      guard p.isWellFormed, p.carrierFrequency > 0 else {
        notes.append("Source \(["A", "B", "C"][i]) has a carrier, width or chirp that is not a usable number: it is left out.")
        continue
      }
      guard let k0 = p.carrierWavenumber(model) else {
        notes.append("Source \(["A", "B", "C"][i]) is below cut-off in \(request.dispersion.title.lowercased()): no wave propagates.")
        continue
      }
      let reach = abs(k0) + 5 * p.spectralWidth
      kMax = max(kMax, reach)
      nuMax = max(nuMax, model.frequency(reach) ?? p.carrierFrequency)
      vMax = max(vMax, max(0.05, abs(model.groupVelocity(p.carrierFrequency) ?? 1)))
      sigmaMax = max(sigmaMax, p.width)
      placed.append(p)
    }
    if kMax == 0 { kMax = 2 * Double.pi }
    if nuMax == 0 { nuMax = 1 }
    if vMax == 0 { vMax = 1 }
    // Rule 2: k band (positive [0, π/Δx) or centred ±π/(2Δx)) ≥ 1.1 k_max; ν band 1/(2Δt) ≥ 1.1 ν_max.
    let forward = !placed.isEmpty && placed.allSatisfy { $0.direction >= 0 }
    let kBand = request.kBand ?? (forward ? .positive : .centered)
    let dx = Double.pi / ((kBand == .positive ? 1 : 2) * 1.1 * kMax)
    let xSpan = Double(n) * dx
    // Time window: as long as the packets (±3σ) stay inside the x window, at least half a crossing.
    let inside = max(xSpan - 6 * sigmaMax, 0.5 * xSpan)
    var dt = inside / vMax / Double(n)
    // The Hann gate's main lobe reaches 2/T beyond the content (T = n·Δt).
    let nuReach = nuMax + (request.observationWindow ? 2 / (Double(n) * dt) : 0)
    dt = min(dt, 1 / (2 * 1.1 * nuReach))
    let tSpan = Double(n) * dt
    let xAxis = Axis(start: -xSpan / 2, step: dx, count: n)
    let tAxis = Axis(start: 0, step: dt, count: n)
    let tMid = tSpan / 2
    // Shift each packet so its envelope is at `center` when t = t_mid.
    let shifted = placed.map { p -> GaussianPacket in
      var q = p
      let v = model.groupVelocity(p.carrierFrequency) ?? 0
      q.center = p.center - Double(p.direction >= 0 ? 1 : -1) * v * tMid
      return q
    }
    let gate = request.observationWindow ? TimeGate.hann(over: tAxis) : nil
    let pf = packetField(shifted, model: model, x: xAxis, t: tAxis, gate: gate)
    if pf.droppedFraction > 1e-6 {
      let pct = pf.droppedFraction * 100
      notes.append(
        "\(String(format: pct >= 10 ? "%.0f" : "%.1g", pct)) % of the packet spectrum has no propagating mode and is left out.")
    }
    // Packets whose envelope never enters the window (a huge `center`) leave the view empty.
    let expected = placed.reduce(0) { $0 + $1.amplitude * $1.amplitude } * tSpan
    if !placed.isEmpty, pf.droppedFraction < 1, pf.field.energy() <= 1e-9 * expected {
      notes.append("The packets lie outside the x window at these times: move them toward the center.")
    }
    if pf.periodLimited {
      notes.append("A packet is far wider (or more chirped) than the window allows; its field is approximate.")
    }
    if placed.contains(where: { !request.dispersion.isValid(frequency: units.hertz($0.carrierFrequency)) }) {
      notes.append("\(request.dispersion.title) has no measured index at this wavelength; the nearest model value is used.")
    }
    let bins = spacetimeBins(request.lagBins, samples: n)
    let w = spacetimeWigner(
      pf.field,
      options: SpacetimeOptions(
        kBins: bins, nuBins: bins, kBand: kBand, nuBand: .positive, keepFull: request.keepFull, kSlice: request.kSlice))
    let spec = spectrum(pf.field, kBins: w.nk, nuBins: w.nnu, kBand: kBand, nuBand: .positive)
    let report = marginalReport(w, field: pf.field)
    if report.status == .aliased {
      notes.append("Part of the packet reaches the edge of the window or band (ALIASED): shorten the pulse or add grid points.")
    }
    let shell = model.shell(kRange: w.kAxis.start...w.kAxis.end, count: 241)
    let carriers: [SIMD2<Double>?] = request.packets.prefix(3).map { p in
      guard refOK, p.isWellFormed, p.carrierFrequency > 0 else { return nil }
      return p.carrierWavenumber(model).map { SIMD2($0, p.carrierFrequency) }
    }
    return PhaseSpaceScene(
      units: units, model: model, field: pf.field, intensity: pf.field.intensityGrid(), spectrum: spec, wigner: w,
      report: report, shell: shell, carriers: carriers, notes: notes)
  }
}
