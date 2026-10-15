import Foundation
import simd

/// Everything the Antenna page draws for one set of antenna knobs, computed off the main actor
/// from `RF.AntennaModel` (the pattern integral can take tens of milliseconds for big arrays).
/// Pure data plumbing: every number comes from the RF engine.
nonisolated struct RadioAntennaBuild: Sendable {
  let model: RF.AntennaModel
  /// Lobe mesh (RF.PatternMesh): unit directions and |F| per vertex, row-major.
  let rows: Int
  let columns: Int
  let directions: [SIMD3<Float>]
  let values: [Float]
  /// E- and H-plane cuts: |F| at angles −180 ..< 180° from the peak (1° steps).
  let eCut: [Double]
  let hCut: [Double]
  /// Phased array: element excitation phases along x and y (radians, from RF's aperture
  /// distribution), for the glyph's travelling glow. Empty for other styles.
  let phaseX: [Float]
  let phaseY: [Float]

  static let meshRows = 61
  static let meshColumns = 72
  static let cutCount = 360

  init(_ parameters: RF.AntennaParameters) {
    let model = RF.AntennaModel(parameters)
    self.model = model
    if model.parameters.style == .phasedArray {
      func phases(_ plane: RF.PatternPlane) -> [Float] {
        guard let d = model.apertureDistribution(plane: plane) else { return [] }
        return (0..<d.samples.count).map { atan2(d.samples.q[$0], d.samples.i[$0]) }
      }
      phaseX = phases(.e)
      phaseY = model.parameters.arrayNy > 1 ? phases(.h) : []
    } else {
      phaseX = []
      phaseY = []
    }
    let focus = RF.PatternMesh.suggestedFocus(for: model, rows: Self.meshRows)
    let mesh = RF.PatternMesh(model: model, rows: Self.meshRows, columns: Self.meshColumns, focus: focus)
    rows = mesh.rows
    columns = mesh.columns
    var dirs = [SIMD3<Float>](repeating: .zero, count: mesh.rows * mesh.columns)
    for i in 0..<mesh.rows {
      for j in 0..<mesh.columns { dirs[i * mesh.columns + j] = mesh.direction(row: i, column: j) }
    }
    directions = dirs
    values = mesh.values
    eCut = model.cut(.e, count: Self.cutCount).values
    hCut = model.cut(.h, count: Self.cutCount).values
  }

  /// A cut in `PolarPlot` order: index i is i° clockwise from the beam peak (dB, floored).
  static func polar(_ cut: [Double], floorDB: Double = -40) -> [Double] {
    let n = cut.count
    guard n > 2 else { return [] }
    return (0..<n).map { i in
      let f = cut[(i + n / 2) % n]
      return f > 0 ? max(floorDB, 20 * log10(f)) : floorDB
    }
  }

  /// Local direction of a cut sample k (angle −180 + 360k/n from the peak toward `axis`).
  static func cutDirection(_ k: Int, count n: Int, peak: SIMD3<Double>, axis: SIMD3<Double>) -> SIMD3<Double> {
    let a = (-180 + 360 * Double(k) / Double(n)) * Double.pi / 180
    return cos(a) * peak + sin(a) * axis
  }
}

/// The "Aperture phase space" view (SPEC-features §3c): the spatial Wigner W(x, kₓ) of the
/// antenna's source distribution (from `RF.AntennaModel.apertureDistribution`), computed by the
/// Phase engine, Fresnel-sheared to a distance z, with its two marginals: |ψ_z(x)|² across the
/// window and the far field (the k marginal, kₓ = k·u) compared with RF's own factor F(u).
nonisolated struct RadioApertureBuild: Sendable {
  /// Display grid of W_z(x, kₓ) over the visible region |kₓ| ≤ k: rows (x, top = +x) × columns
  /// (kₓ from −k to +k), signed, scaled to max |W| = 1.
  var image: [Float] = []
  var rows = 0
  var columns = 0
  /// x window of the image rows (wavelengths).
  var xRange: ClosedRange<Double> = -1...1
  /// |ψ_z(x)|² per display row (Σ over the visible columns), normalized to 1.
  var nearField: [Double] = []
  /// Far field from the Wigner k marginal at u = kₓ/k for each display column, normalized.
  var farField: [Double] = []
  /// RF's factor |F(u)|² at the same u, normalized.
  var rfFactor: [Double] = []
  /// Largest |Phase − RF| of the two normalized patterns.
  var maxDeviation = 0.0
  /// Distance z (wavelengths) and the far-field distance (wavelengths) it was sheared to.
  var distance = 0.0
  var farFieldDistance = 0.0
  /// Aperture extent along its axis (wavelengths).
  var extent = 0.0
  var samples = 0
  var isDiscrete = false
  /// What is sampled ("TE₁₀ cosine across A").
  var description = ""
  /// "sin θ" (apertures, arrays: θ from broadside) or "cos θ" (wires, Yagi boom: θ from the axis).
  var directionCosine = "sin θ"
  /// Axis name of the positions ("x", "y" or "z").
  var axisName = "x"

  static let displayRows = 120
  static let displayColumns = 120

  /// Builds the view for `distribution` sheared to `ratio` × the far-field distance
  /// `farFieldWavelengths` (both from RF). Returns nil when the style has no line source.
  static func make(_ distribution: RF.ApertureDistribution?, ratio: Double, farFieldWavelengths: Double) -> RadioApertureBuild? {
    guard let d = distribution, d.positions.count >= 1 else { return nil }
    var out = RadioApertureBuild()
    let aperture = phaseAperture(d)
    out.samples = d.positions.count
    out.isDiscrete = d.isDiscrete
    out.description = d.description
    out.axisName = d.axis.z > 0.5 ? "z" : (d.axis.y > 0.5 ? "y" : "x")
    out.directionCosine = d.axis.z > 0.5 ? "cos θ" : "sin θ"
    let first = d.positions.first ?? 0
    let last = d.positions.last ?? 0
    // Elements span first…last; a continuous source is sampled at cell midpoints, so it covers
    // count × spacing (a λ/2 dipole: 4 samples λ/8 apart span 0.5λ, not 0.375λ).
    out.extent = d.isDiscrete ? max(last - first, d.spacing) : Double(d.positions.count) * d.spacing
    out.farFieldDistance = farFieldWavelengths.isFinite ? max(farFieldWavelengths, 1e-6) : 1
    let z = max(0, (ratio.isFinite ? ratio : 0) * out.farFieldDistance)
    out.distance = z

    // W(x, kₓ): exact (full lag over the record), centred k band.
    let w = aperture.wigner()
    let k = aperture.wavenumber
    // Shear onto a window that follows the beam out to ±(half extent + z): the paraxial shift
    // is z·kₓ/k ≤ z over the visible region.
    let half = out.extent / 2 * 1.2 + max(d.spacing, 0.5) + z
    let r = displayRows
    let axis = Phase.Axis(start: -half, step: 2 * half / Double(r - 1), count: r)
    let sheared = Phase.fresnelShear(w, distance: z, wavenumber: k, model: .paraxial, rowAxis: axis, interpolation: .cubic)
    out.xRange = -half...half

    // Display columns across the visible region, nearest Wigner column.
    let c = displayColumns
    let us = (0..<c).map { -1 + 2 * (Double($0) + 0.5) / Double(c) }
    let columnIndex = us.map { sheared.columnAxis.nearestIndex($0 * k) }
    var image = [Float](repeating: 0, count: r * c)
    var near = [Double](repeating: 0, count: r)
    var peak = 0.0
    for row in 0..<r {
      // Display row 0 is the top of the well: +x.
      let top = r - 1 - row
      var sum = 0.0
      for (j, col) in columnIndex.enumerated() {
        let v = sheared.value(row: row, column: col)
        image[top * c + j] = Float(v)
        peak = max(peak, abs(v))
        sum += v
      }
      near[top] = max(0, sum)
    }
    if peak > 0 { for i in image.indices { image[i] /= Float(peak) } }
    let nearPeak = near.max() ?? 0
    out.nearField = nearPeak > 0 ? near.map { $0 / nearPeak } : near
    out.image = image
    out.rows = r
    out.columns = c

    // Far field: the Wigner's k marginal (Phase) vs RF's own transform of the same source.
    let angles = us.map { asin(min(1, max(-1, $0))) * 180 / Double.pi }
    let phase = aperture.farField(from: w, anglesDeg: angles).map(\.power)
    let rf = us.map { u -> Double in
      let f = d.factor(directionCosine: u)
      return f.re * f.re + f.im * f.im
    }
    let pPeak = phase.max() ?? 0
    let rPeak = rf.max() ?? 0
    out.farField = pPeak > 0 ? phase.map { $0 / pPeak } : phase
    out.rfFactor = rPeak > 0 ? rf.map { $0 / rPeak } : rf
    out.maxDeviation = zip(out.farField, out.rfFactor).map { abs($0 - $1) }.max() ?? 0
    return out
  }

  /// RF's distribution (engineering e^{+j2πxu}) as a Phase aperture current in convention (C):
  /// the conjugate, so the k marginal at +kₓ is RF's |F(u = kₓ/k)|². Discrete elements sit on a
  /// grid with even samples per spacing and zeros between (`Phase.Aperture.uniformArray`'s
  /// layout), so the visible region fits the centred band; continuous sources get zero guards.
  static func phaseAperture(_ d: RF.ApertureDistribution) -> Phase.Aperture {
    let n = d.positions.count
    if d.isDiscrete {
      let spacing = max(d.spacing, 1e-3)
      var perSpacing = max(2, Int((4 * spacing).rounded(.up)))
      perSpacing += perSpacing & 1
      let dx = spacing / Double(perSpacing)
      // Zero guards out to a record of `minimumRecord` wavelengths: the Wigner's k columns are
      // 1/record apart, so a short array still gets a smooth picture across the visible region.
      let forRecord = Int(((minimumRecord / spacing - Double(n - 1)) / 2).rounded(.up))
      let guardElements = max(2, n / 2, forRecord)
      let count = (n - 1) * perSpacing + 1 + 2 * guardElements * perSpacing
      var re = [Double](repeating: 0, count: count)
      var im = re
      for e in 0..<n {
        let idx = guardElements * perSpacing + e * perSpacing
        re[idx] = Double(d.samples.i[e]) / dx
        im[idx] = -Double(d.samples.q[e]) / dx
      }
      let origin = (d.positions.first ?? 0) - Double(guardElements * perSpacing) * dx
      return Phase.Aperture(
        current: Phase.Signal(re: re, im: im, step: dx, origin: origin, domain: .space), wavelength: 1,
        elementPositions: d.positions, spacingWavelengths: spacing)
    }
    let pad = max(8, n / 4, Int(((minimumRecord / max(d.spacing, 1e-3) - Double(n)) / 2).rounded(.up)))
    var re = [Double](repeating: 0, count: n + 2 * pad)
    var im = re
    for k in 0..<n {
      re[pad + k] = Double(d.samples.i[k])
      im[pad + k] = -Double(d.samples.q[k])
    }
    let origin = (d.positions.first ?? 0) - Double(pad) * d.spacing
    return Phase.Aperture(
      current: Phase.Signal(re: re, im: im, step: d.spacing, origin: origin, domain: .space), wavelength: 1,
      elementPositions: [], spacingWavelengths: nil)
  }

  /// Shortest record (wavelengths, source plus zero guards) handed to the Wigner: about 4 k
  /// columns per wavelength of record land in the visible region |kₓ| ≤ k, so 32λ gives the
  /// 120-column display more than one column each.
  static let minimumRecord = 32.0

  /// Sample spacing (wavelengths) to request from RF for a continuous source: λ/8 keeps the
  /// visible region in the middle half of the k band; very large apertures use λ/4.
  static func requestedSpacing(for model: RF.AntennaModel) -> Double {
    model.largestDimension / model.wavelength > 48 ? 0.25 : 0.125
  }
}
