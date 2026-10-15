import Foundation
import simd

// The spacetime Wigner distribution Φ(ν, k; x, t) of a 1+1-D field (Utkarsh's construction,
// convention C), computed on a grid with half-lags (ξ, τ) = (2m_x Δx, 2m_t Δt):
//
//   Φ[x_i, t_n](k_q, ν_j) = 4ΔxΔt Σ_{m_x, m_t} h_x(m_x) h_t(m_t) ψ*[i−m_x, n−m_t] ψ[i+m_x, n+m_t]
//                            · e^{−i k_q 2m_xΔx} e^{+2πi ν_j 2m_tΔt}
//
// with k_q = s·π/(M_xΔx), ν_j = s·1/(2M_tΔt) and |m| ≤ M/2 − 1 (rule 1).

nonisolated extension Phase {
  /// A complex 1+1-D field ψ(x, t) on a grid, x-major: index = ix·nt + it.
  struct Field: Sendable, Hashable {
    var re: [Double]
    var im: [Double]
    var xAxis: Axis
    var tAxis: Axis

    init(re: [Double], im: [Double], x: Axis, t: Axis) {
      precondition(re.count == x.count * t.count && im.count == re.count, "Phase.Field: size mismatch")
      self.re = re
      self.im = im
      xAxis = x
      tAxis = t
    }

    /// Samples ψ(x, t) of a complex function.
    init(x: Axis, t: Axis, _ f: (Double, Double) -> SIMD2<Double>) {
      var r = [Double](repeating: 0, count: x.count * t.count)
      var i = r
      for ix in 0..<x.count {
        for it in 0..<t.count {
          let v = f(x.value(ix), t.value(it))
          r[ix * t.count + it] = v.x
          i[ix * t.count + it] = v.y
        }
      }
      self.init(re: r, im: i, x: x, t: t)
    }

    var nx: Int { xAxis.count }
    var nt: Int { tAxis.count }

    /// |ψ|², x-major.
    func intensity() -> [Double] { (0..<re.count).map { re[$0] * re[$0] + im[$0] * im[$0] } }
    /// Σ|ψ|² Δx Δt.
    func energy() -> Double { intensity().reduce(0, +) * xAxis.step * tAxis.step }

    /// ψ(x_ix, ·) as a time record.
    func timeSignal(atX ix: Int) -> Signal {
      Signal(
        re: (0..<nt).map { re[ix * nt + $0] }, im: (0..<nt).map { im[ix * nt + $0] }, step: tAxis.step, origin: tAxis.start,
        domain: .time)
    }

    /// ψ(·, t_it) as a spatial record.
    func spaceSignal(atT it: Int) -> Signal {
      Signal(
        re: (0..<nx).map { re[$0 * nt + it] }, im: (0..<nx).map { im[$0 * nt + it] }, step: xAxis.step, origin: xAxis.start,
        domain: .space)
    }

    func sanitized() -> Field {
      var f = self
      for j in 0..<re.count where !(re[j].isFinite && im[j].isFinite) {
        f.re[j] = 0
        f.im[j] = 0
      }
      return f
    }

    static func + (a: Field, b: Field) -> Field {
      precondition(a.re.count == b.re.count, "Phase.Field +: sizes differ")
      return Field(re: zip(a.re, b.re).map(+), im: zip(a.im, b.im).map(+), x: a.xAxis, t: a.tAxis)
    }

    /// Multiplies every sample by w(x, t) (an observation window / apodization).
    func windowed(_ w: (Double, Double) -> Double) -> Field {
      var f = self
      for ix in 0..<nx {
        for it in 0..<nt {
          let v = w(xAxis.value(ix), tAxis.value(it))
          f.re[ix * nt + it] *= v
          f.im[ix * nt + it] *= v
        }
      }
      return f
    }

    /// |ψ(x, t)|² as a grid (rows x, columns t) for the spacetime heat map.
    func intensityGrid() -> Grid2D {
      Grid2D(rowAxis: xAxis, columnAxis: tAxis, rowLabel: "x", columnLabel: "t", values: intensity())
    }
  }

  /// A plain 2-D grid (row-major) for heat maps that are not phase planes: |ψ(x,t)|², |ψ̃(k,ν)|², M2.
  struct Grid2D: Sendable, Hashable {
    var rowAxis: Axis
    var columnAxis: Axis
    var rowLabel: String
    var columnLabel: String
    var values: [Double]

    @inline(__always) func value(row r: Int, column c: Int) -> Double { values[r * columnAxis.count + c] }
    var minValue: Double { values.min() ?? 0 }
    var maxValue: Double { values.max() ?? 0 }
    func floatValues() -> [Float] { values.map { Float($0) } }
    /// Values / max in 0…1 (or −1…1 when negative values exist).
    func unitValues() -> [Float] {
      let s = values.reduce(0) { max($0, abs($1)) }
      guard s > 0 else { return [Float](repeating: 0, count: values.count) }
      return values.map { Float($0 / s) }
    }
    /// (row, column) of the largest value.
    var argMax: (row: Int, column: Int) {
      guard let i = values.indices.max(by: { values[$0] < values[$1] }) else { return (0, 0) }
      return (i / max(1, columnAxis.count), i % max(1, columnAxis.count))
    }
  }

  /// |ψ̃(k, ν)|² of a field on the (k, ν) columns of a spacetime Wigner, plus the aliased form
  /// (the four partners half a Wigner period away in k and/or ν) that M2 equals exactly.
  struct FieldSpectrum: Sendable, Hashable {
    var power: Grid2D
    var aliased: [Double]
    var kMeasure: Double
    var nuMeasure: Double
    var peak: Double { power.maxValue }
  }

  /// ψ̃(k, ν) = ΔxΔt Σ ψ e^{−ik x} e^{+2πiν t} on the 2M_x × 2M_t grid (exact DTFT samples),
  /// reported on the M_x × M_t band columns (k-major).
  static func spectrum(_ field: Field, kBins requestedX: Int, nuBins requestedT: Int, kBand: Band, nuBand: Band) -> FieldSpectrum {
    let mx = max(0, min(requestedX, maxSpacetimeBins))
    let mt = max(0, min(requestedT, maxSpacetimeBins))
    guard mx > 0, mt > 0 else {
      let empty = Grid2D(
        rowAxis: Axis(start: 0, step: 0, count: 0), columnAxis: Axis(start: 0, step: 0, count: 0), rowLabel: "k", columnLabel: "ν",
        values: [])
      return FieldSpectrum(power: empty, aliased: [], kMeasure: 0, nuMeasure: 0)
    }
    let gx = 2 * mx
    let gt = 2 * mt
    var r = [Double](repeating: 0, count: gx * gt)
    var i = r
    for ix in 0..<field.nx {
      for it in 0..<field.nt {
        let v = ix * field.nt + it
        guard field.re[v].isFinite && field.im[v].isFinite else { continue }
        let dst = (ix % gx) * gt + (it % gt)
        r[dst] += field.re[v]
        i[dst] += field.im[v]
      }
    }
    let (zr, zi) = dft2D(re: r, im: i, rows: gx, columns: gt, rowSign: .negative, columnSign: .positive)
    let h = field.xAxis.step * field.tAxis.step
    let h2 = h * h
    var power = [Double](repeating: 0, count: mx * mt)
    var aliased = power
    for ck in 0..<mx {
      let a = kBand.spectrumIndex(column: ck, bins: mx)
      for cn in 0..<mt {
        let b = nuBand.spectrumIndex(column: cn, bins: mt)
        var acc = 0.0
        for (qa, qb) in [(a, b), ((a + mx) % gx, b), (a, (b + mt) % gt), ((a + mx) % gx, (b + mt) % gt)] {
          let idx = qa * gt + qb
          acc += (zr[idx] * zr[idx] + zi[idx] * zi[idx]) * h2
        }
        let idx = a * gt + b
        power[ck * mt + cn] = (zr[idx] * zr[idx] + zi[idx] * zi[idx]) * h2
        aliased[ck * mt + cn] = acc
      }
    }
    let kAxis = columnAxis(domain: .space, step: field.xAxis.step, bins: mx, band: kBand)
    let nuAxis = columnAxis(domain: .time, step: field.tAxis.step, bins: mt, band: nuBand)
    return FieldSpectrum(
      power: Grid2D(rowAxis: kAxis, columnAxis: nuAxis, rowLabel: "k", columnLabel: "ν", values: power), aliased: aliased,
      kMeasure: columnMeasure(step: field.xAxis.step, bins: mx), nuMeasure: columnMeasure(step: field.tAxis.step, bins: mt))
  }

  struct SpacetimeOptions: Sendable, Hashable, Codable {
    /// k bins M_x and ν bins M_t (lag DFT lengths). nil: the next vDSP size ≥ nx (≥ nt), the exact Φ.
    var kBins: Int?
    var nuBins: Int?
    var lagX: LagWindow = .full
    var lagT: LagWindow = .full
    /// `.centered` k shows both branches of the shell (left- and right-moving waves).
    var kBand: Band = .centered
    /// `.positive` ν: positive-frequency fields (rule 2/3).
    var nuBand: Band = .positive
    /// Keep the whole 4-D Φ as Float (nx·nt·M_x·M_t values; 21 MB at 48⁴) for k-slice scrubbing.
    var keepFull: Bool = false
    /// Also return the (x, t, ν) cube at the k column nearest this k (rad per length unit).
    var kSlice: Double?

    init(
      kBins: Int? = nil, nuBins: Int? = nil, lagX: LagWindow = .full, lagT: LagWindow = .full, kBand: Band = .centered,
      nuBand: Band = .positive, keepFull: Bool = false, kSlice: Double? = nil
    ) {
      self.kBins = kBins
      self.nuBins = nuBins
      self.lagX = lagX
      self.lagT = lagT
      self.kBand = kBand
      self.nuBand = nuBand
      self.keepFull = keepFull
      self.kSlice = kSlice
    }
  }

  /// Φ(ν, k; x, t) on a grid with its reductions.
  struct SpacetimeWigner: Sendable, Hashable {
    var xAxis: Axis
    var tAxis: Axis
    var kAxis: Axis
    var nuAxis: Axis
    var kBand: Band
    var nuBand: Band
    /// dk/2π and dν per column.
    var kMeasure: Double
    var nuMeasure: Double
    /// M1 = Σ Φ dk/2π dν on (x, t), x-major (≈ |ψ|²).
    var m1: [Double]
    /// M2 = Σ Φ Δx Δt on (k, ν), k-major (≈ |ψ̃|²).
    var m2: [Double]
    /// P = Σ Φ Δx Δt dk/2π dν.
    var total: Double
    /// Σ_k Φ dk/2π: the (x, t, ν) cube = temporal Wigner W(t, ν) at each x.
    var kIntegrated: Cube
    /// Σ_ν Φ dν: the (x, t, k) cube = spatial Wigner W(x, k) at each t.
    var nuIntegrated: Cube
    /// Φ at one k column (x, t, ν), when `SpacetimeOptions.kSlice` was set.
    var kSlice: Cube?
    var kSliceIndex: Int?
    /// The whole Φ as Float, index ((ix·nt + it)·M_x + ck)·M_t + cν, when `keepFull` was set.
    var full: [Float]?
    var minValue: Double
    var maxValue: Double
    /// (ix, it, ck, cν) of the most negative and most positive Φ.
    var argMin: [Int]
    var argMax: [Int]
    /// Largest |Im Φ| relative to the largest |Re Φ| (reality; Φ* = Φ).
    var imaginaryResidual: Double
    /// True when the lag windows were full and covered the grid: M2 equals the aliased |ψ̃|²
    /// to round-off. False for pseudo windows (M2 is then smoothed by design).
    var exactM2: Bool
    /// Wall time of the computation, seconds.
    var elapsed: Double

    var nk: Int { kAxis.count }
    var nnu: Int { nuAxis.count }

    /// M2 as a (k, ν) grid.
    var m2Grid: Grid2D { Grid2D(rowAxis: kAxis, columnAxis: nuAxis, rowLabel: "k", columnLabel: "ν", values: m2) }
    /// M1 as an (x, t) grid.
    var m1Grid: Grid2D { Grid2D(rowAxis: xAxis, columnAxis: tAxis, rowLabel: "x", columnLabel: "t", values: m1) }

    /// Φ at one grid point (needs `keepFull`; nil for an index outside the grid).
    func value(ix: Int, it: Int, ck: Int, cnu: Int) -> Double? {
      guard let full, (0..<xAxis.count).contains(ix), (0..<tAxis.count).contains(it), (0..<nk).contains(ck),
        (0..<nnu).contains(cnu)
      else { return nil }
      return Double(full[((ix * tAxis.count + it) * nk + ck) * nnu + cnu])
    }

    /// The (x, t, ν) cube at k column `ck` (needs `keepFull`, or the precomputed slice; nil for a
    /// column outside 0..<nk).
    func kSliceCube(column ck: Int) -> Cube? {
      if let kSlice, kSliceIndex == ck { return kSlice }
      guard let full, (0..<nk).contains(ck) else { return nil }
      var v = [Double](repeating: 0, count: xAxis.count * tAxis.count * nnu)
      for p in 0..<(xAxis.count * tAxis.count) {
        for c in 0..<nnu { v[p * nnu + c] = Double(full[(p * nk + ck) * nnu + c]) }
      }
      return Cube(axisA: xAxis, axisB: tAxis, axisC: nuAxis, labels: ["x", "t", "ν"], values: v)
    }

    /// Partial marginal at fixed t: the spatial Wigner W(x, k) (rows x, columns k).
    func spatialWigner(atT it: Int) -> Plane {
      let nt = tAxis.count
      var v = [Double](repeating: 0, count: xAxis.count * nk)
      for ix in 0..<xAxis.count {
        for c in 0..<nk { v[ix * nk + c] = nuIntegrated.values[(ix * nt + it) * nk + c] }
      }
      return Plane(
        kind: exactM2 ? .wigner : .pseudoWigner, domain: .space, rowAxis: xAxis, columnAxis: kAxis, band: kBand, values: v,
        rowMeasure: xAxis.step, columnMeasure: kMeasure, imaginaryResidual: imaginaryResidual,
        rowIndices: Array(0..<xAxis.count), coversRecord: exactM2)
    }

    /// Partial marginal at fixed x: the temporal Wigner W(t, ν) (rows t, columns ν).
    func temporalWigner(atX ix: Int) -> Plane {
      let nt = tAxis.count
      var v = [Double](repeating: 0, count: nt * nnu)
      for it in 0..<nt {
        for c in 0..<nnu { v[it * nnu + c] = kIntegrated.values[(ix * nt + it) * nnu + c] }
      }
      return Plane(
        kind: exactM2 ? .wigner : .pseudoWigner, domain: .time, rowAxis: tAxis, columnAxis: nuAxis, band: nuBand, values: v,
        rowMeasure: tAxis.step, columnMeasure: nuMeasure, imaginaryResidual: imaginaryResidual,
        rowIndices: Array(0..<nt), coversRecord: exactM2)
    }
  }

  /// Computes Φ for every grid point (direct FFT over the half-lags, rules 1–2), with M1, M2, P,
  /// both partial-marginal cubes and optionally a k slice or the whole 4-D array.
  ///
  /// Cost ∝ nx·nt·(M_t DFTs of M_x + ≤ M_x/2 DFTs of M_t): a 48 × 48 grid with 48 × 48 lags
  /// runs in tens of milliseconds on Apple silicon (`Tools/check-phase.sh` prints it). It is a
  /// pure function: call it from `Task.detached`, never on the main actor during a gesture.
  static func spacetimeWigner(_ input: Field, options: SpacetimeOptions = SpacetimeOptions()) -> SpacetimeWigner {
    let start = Date()
    var field = input.sanitized()
    // A grid without usable steps (0, NaN, ±∞) has no k or ν axis: treat it as empty.
    if !(isUsableStep(field.xAxis.step) && isUsableStep(field.tAxis.step)) {
      field = Field(
        re: [], im: [], x: Axis(start: 0, step: 1, count: 0), t: Axis(start: 0, step: 1, count: 0))
    }
    let nx = field.nx
    let nt = field.nt
    let mx = spacetimeBins(options.kBins, samples: nx)
    let mt = spacetimeBins(options.nuBins, samples: nt)
    let hx = options.lagX.weights(maxHalfWidth: mx / 2 - 1)
    let ht = options.lagT.weights(maxHalfWidth: mt / 2 - 1)
    let lx = hx.count - 1
    let lt = ht.count - 1
    let dx = field.xAxis.step
    let dt = field.tAxis.step
    let kAxis = columnAxis(domain: .space, step: dx, bins: mx, band: options.kBand)
    let nuAxis = columnAxis(domain: .time, step: dt, bins: mt, band: options.nuBand)
    let kMeasure = columnMeasure(step: dx, bins: mx)
    let nuMeasure = columnMeasure(step: dt, bins: mt)
    let exact =
      options.lagX.isRectangular && options.lagT.isRectangular && lx >= (nx - 1) / 2 && lt >= (nt - 1) / 2
    // Inverse column maps: DFT bin → band column.
    var colOfQ = [Int](repeating: 0, count: mx)
    for c in 0..<mx { colOfQ[options.kBand.dftIndex(column: c, bins: mx)] = c }
    var colOfJ = [Int](repeating: 0, count: mt)
    for c in 0..<mt { colOfJ[options.nuBand.dftIndex(column: c, bins: mt)] = c }
    let sliceColumn = options.kSlice.map { kAxis.nearestIndex($0) }

    var m1 = [Double](repeating: 0, count: nx * nt)
    var m2 = [Double](repeating: 0, count: mx * mt)
    var kInt = [Double](repeating: 0, count: nx * nt * mt)
    var nuInt = [Double](repeating: 0, count: nx * nt * mx)
    var slice: [Double]? = sliceColumn.map { _ in [Double](repeating: 0, count: nx * nt * mt) }
    // The 4-D array only when it fits `maxFullValues` (48⁴ = 5.3 M is far below; a 256² grid
    // with 256² lags would be 17 GB).
    let keepFull = options.keepFull && Double(nx) * Double(nt) * Double(mx) * Double(mt) <= Double(maxFullValues)
    var full: [Float]? = keepFull ? [Float](repeating: 0, count: nx * nt * mx * mt) : nil
    var minV = Double.infinity
    var maxV = -Double.infinity
    var argMin = [0, 0, 0, 0]
    var argMax = [0, 0, 0, 0]
    var maxIm = 0.0
    var maxRe = 0.0

    let dftT = DFT(count: mt)
    let dftX = DFT(count: mx)
    // Stage-1 rows S_mx[j] for mx = 0…lx (mx < 0 rows are their conjugates).
    var sRe = [Double](repeating: 0, count: (lx + 1) * mt)
    var sIm = sRe
    var inRe = [Double](repeating: 0, count: max(mx, mt))
    var inIm = inRe
    var outRe = inRe
    var outIm = inRe
    var phi = [Double](repeating: 0, count: mx * mt)  // [q * mt + j]
    let scale = 4 * dx * dt
    let cellArea = dx * dt
    let spectralCell = kMeasure * nuMeasure

    field.re.withUnsafeBufferPointer { pr in
      field.im.withUnsafeBufferPointer { pi in
        for ix in 0..<nx {
          for it in 0..<nt {
            let mxMax = min(lx, ix, nx - 1 - ix)
            let mtMax = min(lt, it, nt - 1 - it)
            // Stage 1: along the time half-lag (sign +, convention C) for each m_x ≥ 0.
            for mxi in 0...mxMax {
              for j in 0..<mt {
                inRe[j] = 0
                inIm[j] = 0
              }
              let rowA = (ix - mxi) * nt
              let rowB = (ix + mxi) * nt
              let w = hx[mxi]
              for mti in -mtMax...mtMax {
                let a = rowA + it - mti
                let b = rowB + it + mti
                let ar = pr[a]
                let ai = pi[a]
                let br = pr[b]
                let bi = pi[b]
                let ww = w * ht[abs(mti)]
                let slot = mti >= 0 ? mti : mt + mti
                inRe[slot] = ww * (ar * br + ai * bi)
                inIm[slot] = ww * (ar * bi - ai * br)
              }
              sRe.withUnsafeMutableBufferPointer { sr in
                sIm.withUnsafeMutableBufferPointer { si in
                  dftT.execute(
                    .positive, inputReal: inRe, inputImag: inIm, outputReal: sr.baseAddress! + mxi * mt,
                    outputImag: si.baseAddress! + mxi * mt)
                }
              }
            }
            // Stage 2: along the space half-lag (sign −), Φ(q, j) = 2·Re U_j(q) − S_0[j].
            for j in 0..<mt {
              let s0 = sRe[j]
              maxIm = max(maxIm, abs(sIm[j]))
              if mxMax == 0 {
                for q in 0..<mx { phi[q * mt + j] = scale * s0 }
                continue
              }
              for q in 0..<mx {
                inRe[q] = 0
                inIm[q] = 0
              }
              for mxi in 0...mxMax {
                inRe[mxi] = sRe[mxi * mt + j]
                inIm[mxi] = sIm[mxi * mt + j]
              }
              dftX.execute(.negative, inputReal: inRe, inputImag: inIm, outputReal: &outRe, outputImag: &outIm)
              for q in 0..<mx { phi[q * mt + j] = scale * (2 * outRe[q] - s0) }
            }
            // Reductions.
            let p = ix * nt + it
            var m1acc = 0.0
            for q in 0..<mx {
              let ck = colOfQ[q]
              var nuAcc = 0.0
              for j in 0..<mt {
                let v = phi[q * mt + j]
                let cn = colOfJ[j]
                nuAcc += v
                m2[ck * mt + cn] += v * cellArea
                kInt[p * mt + cn] += v * kMeasure
                if v < minV {
                  minV = v
                  argMin = [ix, it, ck, cn]
                }
                if v > maxV {
                  maxV = v
                  argMax = [ix, it, ck, cn]
                }
                maxRe = max(maxRe, abs(v))
              }
              nuInt[p * mx + ck] = nuAcc * nuMeasure
              m1acc += nuAcc
              if ck == sliceColumn {
                for j in 0..<mt { slice![p * mt + colOfJ[j]] = phi[q * mt + j] }
              }
              if full != nil {
                let base = (p * mx + ck) * mt
                for j in 0..<mt { full![base + colOfJ[j]] = Float(phi[q * mt + j]) }
              }
            }
            m1[p] = m1acc * spectralCell
          }
        }
      }
    }
    let total = m1.reduce(0, +) * cellArea
    let cubeKInt = Cube(axisA: field.xAxis, axisB: field.tAxis, axisC: nuAxis, labels: ["x", "t", "ν"], values: kInt)
    let cubeNuInt = Cube(axisA: field.xAxis, axisB: field.tAxis, axisC: kAxis, labels: ["x", "t", "k"], values: nuInt)
    let sliceCube = slice.map { Cube(axisA: field.xAxis, axisB: field.tAxis, axisC: nuAxis, labels: ["x", "t", "ν"], values: $0) }
    // S_0 is Σ of a Hermitian lag product scaled by 1; relate its imaginary part to Φ's scale.
    let residual = maxRe > 0 ? maxIm * scale / maxRe : 0
    return SpacetimeWigner(
      xAxis: field.xAxis, tAxis: field.tAxis, kAxis: kAxis, nuAxis: nuAxis, kBand: options.kBand, nuBand: options.nuBand,
      kMeasure: kMeasure, nuMeasure: nuMeasure, m1: m1, m2: m2, total: total, kIntegrated: cubeKInt, nuIntegrated: cubeNuInt,
      kSlice: sliceCube, kSliceIndex: sliceColumn, full: full, minValue: minV.isFinite ? minV : 0,
      maxValue: maxV.isFinite ? maxV : 0, argMin: argMin, argMax: argMax, imaginaryResidual: residual, exactM2: exact,
      elapsed: Date().timeIntervalSince(start))
  }

  /// Reference Φ at one grid point by a plain complex 2-D DFT of the full lag product (no
  /// symmetry shortcut), returning real and imaginary parts on the (k, ν) band columns (k-major).
  /// Used by the oracles to check the fast path and reality (Im Φ ≈ 0).
  static func spacetimeWignerPoint(
    _ field: Field, ix: Int, it: Int, options: SpacetimeOptions = SpacetimeOptions()
  ) -> (re: [Double], im: [Double]) {
    let nx = field.nx
    let nt = field.nt
    let mx = spacetimeBins(options.kBins, samples: nx)
    let mt = spacetimeBins(options.nuBins, samples: nt)
    let hx = options.lagX.weights(maxHalfWidth: mx / 2 - 1)
    let ht = options.lagT.weights(maxHalfWidth: mt / 2 - 1)
    var r = [Double](repeating: 0, count: mx * mt)
    var i = r
    for a in -(hx.count - 1)...(hx.count - 1) {
      for b in -(ht.count - 1)...(ht.count - 1) {
        let x1 = ix - a
        let x2 = ix + a
        let t1 = it - b
        let t2 = it + b
        guard x1 >= 0, x2 < nx, x2 >= 0, x1 < nx, t1 >= 0, t2 < nt, t2 >= 0, t1 < nt else { continue }
        let p1 = x1 * nt + t1
        let p2 = x2 * nt + t2
        let w = hx[abs(a)] * ht[abs(b)]
        let idx = ((a + mx) % mx) * mt + ((b + mt) % mt)
        r[idx] = w * (field.re[p1] * field.re[p2] + field.im[p1] * field.im[p2])
        i[idx] = w * (field.re[p1] * field.im[p2] - field.im[p1] * field.re[p2])
      }
    }
    let (fr, fi) = dft2D(re: r, im: i, rows: mx, columns: mt, rowSign: .negative, columnSign: .positive)
    let scale = 4 * field.xAxis.step * field.tAxis.step
    var outR = [Double](repeating: 0, count: mx * mt)
    var outI = outR
    for ck in 0..<mx {
      let q = options.kBand.dftIndex(column: ck, bins: mx)
      for cn in 0..<mt {
        let j = options.nuBand.dftIndex(column: cn, bins: mt)
        outR[ck * mt + cn] = scale * fr[q * mt + j]
        outI[ck * mt + cn] = scale * fi[q * mt + j]
      }
    }
    return (outR, outI)
  }

  /// Lag DFT length per axis: the request made even and clamped to 4…`maxSpacetimeBins`, or the
  /// next vDSP size ≥ the sample count (the exact Φ) when nil.
  static func spacetimeBins(_ requested: Int?, samples n: Int) -> Int {
    requested.map { evenBins($0, cap: maxSpacetimeBins) } ?? min(DFT.goodSize(atLeast: max(n, 8)), maxSpacetimeBins)
  }

  // MARK: Marginal report (the "Marginals" strip)

  struct MarginalReport: Sendable, Hashable {
    enum Status: String, Sendable, Hashable, Codable {
      /// M1, M2 (alias identity) and P hold to round-off and the alias is below `aliasTolerance`.
      case consistent
      /// Identities hold but content sits within half a period of the band edge (rule 2):
      /// sample finer or oversample 2×.
      case aliased
      /// Pseudo/smoothed windows: M1 and P exact, M2 smoothed by design (rule 5).
      case smoothed
      /// An identity failed (a bug; never expected).
      case inconsistent

      var badge: String {
        switch self {
        case .consistent: "CONSISTENT"
        case .aliased: "ALIASED"
        case .smoothed: "SMOOTHED"
        case .inconsistent: "INCONSISTENT"
        }
      }
    }

    /// max |M1 − |ψ|²| / max |ψ|².
    var m1Error: Double
    /// max |M2 − (|ψ̃|² + aliases)| / max |ψ̃|² (exact identity).
    var m2IdentityError: Double
    /// max |M2 − |ψ̃|²| / max |ψ̃|² (bounded by the alias level).
    var m2Error: Double
    /// max alias / max |ψ̃|².
    var aliasLevel: Double
    /// |P − Σ|ψ|²ΔxΔt| / Σ|ψ|²ΔxΔt.
    var parsevalError: Double
    /// |Σ (|ψ̃|² + aliases) dk/2π dν − Σ|ψ|²ΔxΔt| / Σ|ψ|²ΔxΔt (Parseval on the spectrum side).
    var spectralParsevalError: Double
    var realityResidual: Double
    var energy: Double
    var status: Status
  }

  /// The report of `w` against the field it was computed from. The field is sanitized exactly as
  /// `spacetimeWigner` does (non-finite samples count as 0). A `w` that does not belong to this
  /// field (different grid, or a grid without usable steps) reports infinite errors and
  /// INCONSISTENT instead of trapping on an index.
  static func marginalReport(_ w: SpacetimeWigner, field input: Field) -> MarginalReport {
    let field = input.sanitized()
    let inten = field.intensity()
    let e = field.energy()
    guard isUsableStep(field.xAxis.step), isUsableStep(field.tAxis.step), w.xAxis.count == field.nx,
      w.tAxis.count == field.nt, w.m1.count == inten.count, w.m2.count == w.nk * w.nnu
    else {
      return MarginalReport(
        m1Error: .infinity, m2IdentityError: .infinity, m2Error: .infinity, aliasLevel: .infinity, parsevalError: .infinity,
        spectralParsevalError: .infinity, realityResidual: w.imaginaryResidual, energy: e.isFinite ? e : 0, status: .inconsistent)
    }
    let iPeak = max(inten.max() ?? 0, .leastNormalMagnitude)
    var m1Err = 0.0
    for p in 0..<inten.count { m1Err = max(m1Err, abs(w.m1[p] - inten[p])) }
    let spec = spectrum(field, kBins: w.nk, nuBins: w.nnu, kBand: w.kBand, nuBand: w.nuBand)
    let sPeak = max(spec.peak, .leastNormalMagnitude)
    var idErr = 0.0
    var m2Err = 0.0
    var alias = 0.0
    var specTotal = 0.0
    for p in 0..<w.m2.count {
      idErr = max(idErr, abs(w.m2[p] - spec.aliased[p]))
      m2Err = max(m2Err, abs(w.m2[p] - spec.power.values[p]))
      alias = max(alias, spec.aliased[p] - spec.power.values[p])
      specTotal += spec.aliased[p]
    }
    specTotal *= spec.kMeasure * spec.nuMeasure
    // Parseval on the spectrum side holds for the record folded onto the 2M_x × 2M_t grid the
    // spectrum samples (the field itself when 2M ≥ N in both axes, as for the exact Φ). Bins
    // smaller than half the record fold it; comparing with the unfolded energy would then flag
    // a correct pseudo Φ as INCONSISTENT.
    let gx = 2 * w.nk
    let gt = 2 * w.nnu
    var folded = e
    if gx < field.nx || gt < field.nt {
      var fr = [Double](repeating: 0, count: gx * gt)
      var fi = fr
      for ix in 0..<field.nx {
        for it in 0..<field.nt {
          let d = (ix % gx) * gt + (it % gt)
          fr[d] += field.re[ix * field.nt + it]
          fi[d] += field.im[ix * field.nt + it]
        }
      }
      folded = zip(fr, fi).reduce(0) { $0 + $1.0 * $1.0 + $1.1 * $1.1 } * field.xAxis.step * field.tAxis.step
    }
    let eSafe = max(abs(e), .leastNormalMagnitude)
    let report = MarginalReport(
      m1Error: m1Err / iPeak, m2IdentityError: idErr / sPeak, m2Error: m2Err / sPeak, aliasLevel: alias / sPeak,
      parsevalError: abs(w.total - e) / eSafe, spectralParsevalError: abs(specTotal - folded) / max(abs(folded), .leastNormalMagnitude),
      realityResidual: w.imaginaryResidual, energy: e, status: .consistent)
    var r = report
    let tol = identityTolerance
    if r.m1Error > tol || r.parsevalError > tol || r.spectralParsevalError > tol {
      r.status = .inconsistent
    } else if !w.exactM2 {
      r.status = .smoothed
    } else if r.m2IdentityError > tol {
      r.status = .inconsistent
    } else if r.aliasLevel > aliasTolerance {
      r.status = .aliased
    }
    return r
  }
}
