import Foundation

nonisolated extension Phase {
  /// Lag window h(m) on the half-lag m (h(0) = 1, symmetric). `.full` is the exact Wigner:
  /// rectangular out to M/2 − 1, the largest half-lag rule 1 allows. Anything shorter than the
  /// record makes a pseudo-Wigner (the frequency marginal is then smoothed; the time marginal
  /// stays exact because h(0) = 1).
  enum LagWindow: Sendable, Hashable, Codable {
    case full
    case rectangular(halfWidth: Int)
    case hann(halfWidth: Int)
    case gaussian(halfWidth: Int, sigma: Double)

    /// h(0…L) with L ≤ maxHalfWidth.
    func weights(maxHalfWidth: Int) -> [Double] {
      let cap = max(0, maxHalfWidth)
      switch self {
      case .full:
        return [Double](repeating: 1, count: cap + 1)
      case .rectangular(let l):
        return [Double](repeating: 1, count: min(cap, max(0, l)) + 1)
      case .hann(let l):
        let w = min(cap, max(0, l))
        return (0...w).map { 0.5 * (1 + cos(Double.pi * Double($0) / Double(w + 1))) }
      case .gaussian(let l, let sigma):
        let w = min(cap, max(0, l))
        let s = Phase.windowSigma(sigma)
        return (0...w).map { exp(-0.5 * Double($0 * $0) / (s * s)) }
      }
    }

    var isRectangular: Bool {
      switch self {
      case .full, .rectangular: true
      default: false
      }
    }
  }

  /// Time (or space) smoothing window g(p) of the smoothed pseudo-Wigner, normalized to Σg = 1
  /// so a constant |z|² is unchanged.
  enum SmoothingWindow: Sendable, Hashable, Codable {
    case none
    case hann(halfWidth: Int)
    case gaussian(halfWidth: Int, sigma: Double)

    /// Largest half-width G (2¹⁶ samples each side).
    static let maxHalfWidth = 1 << 16

    /// g(−G…G) normalized to sum 1 (G clamped to 0…`maxHalfWidth`).
    var weights: [Double] {
      var w: [Double]
      switch self {
      case .none:
        return [1]
      case .hann(let l):
        let g = min(max(0, l), Self.maxHalfWidth)
        w = (-g...g).map { 0.5 * (1 + cos(Double.pi * Double($0) / Double(g + 1))) }
      case .gaussian(let l, let sigma):
        let g = min(max(0, l), Self.maxHalfWidth)
        let s = Phase.windowSigma(sigma)
        w = (-g...g).map { exp(-0.5 * Double($0) * Double($0) / (s * s)) }
      }
      let total = w.reduce(0, +)
      return w.map { $0 / total }
    }
  }

  /// Which samples become rows.
  enum RowSelection: Sendable, Hashable, Codable {
    /// Every sample (needed for the exact M2 identity).
    case all
    /// `count` rows spread evenly over the record (live views: 256 rows of a long stream).
    case count(Int)
    /// Every `n`-th sample.
    case stride(Int)

    func indices(samples n: Int) -> [Int] {
      guard n > 0 else { return [] }
      switch self {
      case .all:
        return Array(0..<n)
      case .stride(let s):
        return Array(Swift.stride(from: 0, to: n, by: max(1, s)))
      case .count(let k):
        let kk = max(1, min(k, n))
        if kk == 1 { return [n / 2] }
        return (0..<kk).map { Int((Double($0) * Double(n - 1) / Double(kk - 1)).rounded()) }
      }
    }
  }

  struct WignerOptions: Sendable, Hashable, Codable {
    /// Lag DFT length M = number of frequency (or k) columns over one Wigner period. nil picks
    /// the next vDSP size ≥ N (exact Wigner of the whole record).
    var bins: Int?
    var lag: LagWindow = .full
    var smoothing: SmoothingWindow = .none
    var rows: RowSelection = .all
    /// nil: `.positive` for time (analytic streams), `.centered` for space.
    var band: Band?
    /// Average groups of columns after the transform (preserves the time marginal).
    var columnBinning: Int = 1

    init(
      bins: Int? = nil, lag: LagWindow = .full, smoothing: SmoothingWindow = .none, rows: RowSelection = .all,
      band: Band? = nil, columnBinning: Int = 1
    ) {
      self.bins = bins
      self.lag = lag
      self.smoothing = smoothing
      self.rows = rows
      self.band = band
      self.columnBinning = columnBinning
    }
  }

  /// Discrete Wigner distribution of a 1-D record in convention (C):
  ///
  ///     time:  W(t_n, ν) = 2Δt Σ_m h(m) Σ_p g(p) z*[n−p−m] z[n−p+m] e^{+2πiν·2mΔt}
  ///     space: W(x_n, k) = 2Δx Σ_m h(m) Σ_p g(p) ψ*[n−p−m] ψ[n−p+m] e^{−ik·2mΔx}
  ///
  /// on the M columns ν_c = s·fs/(2M) (k_c = s·π/(MΔx)) of the chosen band. Half-lags obey
  /// |m| ≤ M/2 − 1 and samples outside the record are zero (rule 1). Real streams must be made
  /// analytic first (rule 3); complex fields must be 2× oversampled for `.centered` (rule 2).
  ///
  /// Cost: rows × (L products + one M-point vDSP DFT); 256 × 256 takes well under a millisecond
  /// on Apple silicon (`Tools/check-phase.sh` prints the timing).
  static func wigner(_ signal: Signal, options: WignerOptions = WignerOptions()) -> Plane {
    let s = signal.sanitized()
    // A record without a usable step (0, NaN, ±∞: e.g. a stream whose rate is still unknown)
    // has no axis: return an empty plane rather than NaN columns.
    guard isUsableStep(s.step) else { return emptyPlane(kind: .wigner, signal: s, band: options.band) }
    let n = s.count
    let m = options.bins.map { evenBins($0) } ?? min(DFT.goodSize(atLeast: max(n, 8)), maxBins)
    let band = options.band ?? (s.domain == .time ? .positive : .centered)
    let h = options.lag.weights(maxHalfWidth: m / 2 - 1)
    let lagHalf = h.count - 1
    let g = options.smoothing.weights
    let gHalf = (g.count - 1) / 2
    let rowIdx = boundedRows(options.rows, samples: n, columns: m)
    let columnAxis = columnAxis(domain: s.domain, step: s.step, bins: m, band: band)
    let coversLag = lagHalf >= (n - 1) / 2
    let kind: PlaneKind =
      gHalf > 0 ? .smoothedPseudoWigner : (options.lag.isRectangular && coversLag ? .wigner : .pseudoWigner)
    let rowAxis = rowAxisFor(rowIdx, samples: n, step: s.step, origin: s.origin)
    var plane = Plane(
      kind: kind, domain: s.domain, rowAxis: rowAxis, columnAxis: columnAxis, band: band,
      values: [Double](repeating: 0, count: rowIdx.count * m), rowMeasure: rowMeasureFor(rowIdx, samples: n, step: s.step),
      columnMeasure: columnMeasure(step: s.step, bins: m), imaginaryResidual: 0, rowIndices: rowIdx,
      coversRecord: kind == .wigner && rowIdx.count == n)
    guard n > 0, !rowIdx.isEmpty else { return plane }

    let dft = DFT(count: m)
    let sign: DFT.Sign = s.domain == .time ? .positive : .negative
    let scale = 2 * s.step
    var inRe = [Double](repeating: 0, count: m)
    var inIm = inRe
    var outRe = inRe
    var outIm = inRe
    // Column c reads DFT bin q(c).
    let binOf = (0..<m).map { band.dftIndex(column: $0, bins: m) }
    var maxRe = 0.0
    var maxIm = 0.0
    s.re.withUnsafeBufferPointer { zr in
      s.im.withUnsafeBufferPointer { zi in
        plane.values.withUnsafeMutableBufferPointer { out in
          for (r, n0) in rowIdx.enumerated() {
            for j in 0..<m {
              inRe[j] = 0
              inIm[j] = 0
            }
            let mMax = min(lagHalf, n0 + gHalf, n - 1 - n0 + gHalf)
            if mMax >= 0 {
              for mm in 0...mMax {
                var accR = 0.0
                var accI = 0.0
                for p in -gHalf...gHalf {
                  let c = n0 - p
                  let a = c - mm
                  let b = c + mm
                  if a < 0 || b >= n { continue }
                  let w = g[p + gHalf]
                  let ar = zr[a]
                  let ai = zi[a]
                  let br = zr[b]
                  let bi = zi[b]
                  accR += w * (ar * br + ai * bi)
                  accI += w * (ar * bi - ai * br)
                }
                accR *= h[mm]
                accI *= h[mm]
                inRe[mm] = accR
                inIm[mm] = accI
                if mm > 0 {
                  inRe[m - mm] = accR
                  inIm[m - mm] = -accI
                }
              }
            }
            dft.execute(sign, inputReal: inRe, inputImag: inIm, outputReal: &outRe, outputImag: &outIm)
            let base = r * m
            for c in 0..<m {
              let q = binOf[c]
              out[base + c] = scale * outRe[q]
              maxRe = max(maxRe, abs(outRe[q]))
              maxIm = max(maxIm, abs(outIm[q]))
            }
          }
        }
      }
    }
    plane.imaginaryResidual = maxRe > 0 ? maxIm / maxRe : 0
    return options.columnBinning > 1 ? plane.binnedColumns(options.columnBinning) : plane
  }

  /// Wigner–Ville distribution of a real stream: analytic signal (rule 3) then `wigner`.
  static func wignerVille(
    real x: [Double], step: Double, origin: Double = 0, domain: Domain = .time, options: WignerOptions = WignerOptions()
  ) -> Plane {
    var o = options
    if o.band == nil { o.band = .positive }
    return wigner(Signal.analytic(real: x, step: step, origin: origin, domain: domain), options: o)
  }

  // MARK: Spectrogram

  /// Analysis window of the spectrogram, centred on each row's sample.
  enum SpectrogramWindow: Sendable, Hashable, Codable {
    case hann(length: Int)
    case gaussian(length: Int, sigma: Double)
    case rectangular(length: Int)

    /// 1 … 2·`maxBins` (the spectrogram never uses more than its 2M-point frame).
    var length: Int {
      switch self {
      case .hann(let l), .gaussian(let l, _), .rectangular(let l): min(max(1, l), 2 * Phase.maxBins)
      }
    }

    /// Raw window samples at offsets −⌊(L−1)/2⌋ … A window with no energy (a Gaussian whose σ is
    /// far below one sample on an even length) becomes a one-sample impulse, not 0/0.
    var samples: [Double] {
      let l = length
      let c = Double(l - 1) / 2
      var w: [Double]
      switch self {
      case .hann:
        w = (0..<l).map { 0.5 * (1 + cos(2 * Double.pi * (Double($0) - c) / Double(l + 1))) }
      case .gaussian(_, let sigma):
        let s = Phase.windowSigma(sigma)
        w = (0..<l).map { exp(-0.5 * (Double($0) - c) * (Double($0) - c) / (s * s)) }
      case .rectangular:
        w = [Double](repeating: 1, count: l)
      }
      if !(w.reduce(0) { $0 + $1 * $1 } > 0) {
        w = [Double](repeating: 0, count: l)
        w[(l - 1) / 2] = 1
      }
      return w
    }
  }

  /// Spectrogram |STFT|² on the same column grid as an M-bin Wigner (so they sit side by side):
  /// S(t_n, ν) = |Δt Σ_p z[n+p] w[p] e^{+2πiν pΔt}|² with Δt Σ w² = 1 (convention C sign; space
  /// uses e^{−ik pΔx}). Always ≥ 0, blurred by the window; its time marginal is |z|² smoothed by
  /// w², its frequency marginal |Z|² smoothed by |ŵ|².
  static func spectrogram(
    _ signal: Signal, window: SpectrogramWindow, bins: Int, rows: RowSelection = .all, band: Band? = nil
  ) -> Plane {
    let s = signal.sanitized()
    guard isUsableStep(s.step) else { return emptyPlane(kind: .spectrogram, signal: s, band: band) }
    let n = s.count
    let m = evenBins(bins)
    let g2 = 2 * m
    let band = band ?? (s.domain == .time ? .positive : .centered)
    var w = window.samples
    if w.count > g2 { w = Array(w[((w.count - g2) / 2)..<((w.count - g2) / 2 + g2)]) }
    let norm = 1 / (w.reduce(0) { $0 + $1 * $1 } * abs(s.step)).squareRoot()
    w = w.map { $0 * norm }
    let lo = -(w.count - 1) / 2
    let rowIdx = boundedRows(rows, samples: n, columns: m)
    var plane = Plane(
      kind: .spectrogram, domain: s.domain, rowAxis: rowAxisFor(rowIdx, samples: n, step: s.step, origin: s.origin),
      columnAxis: columnAxis(domain: s.domain, step: s.step, bins: m, band: band), band: band,
      values: [Double](repeating: 0, count: rowIdx.count * m), rowMeasure: rowMeasureFor(rowIdx, samples: n, step: s.step),
      columnMeasure: columnMeasure(step: s.step, bins: m), imaginaryResidual: 0, rowIndices: rowIdx, coversRecord: false)
    guard n > 0, !rowIdx.isEmpty else { return plane }
    let dft = DFT(count: g2)
    let sign: DFT.Sign = s.domain == .time ? .positive : .negative
    var inRe = [Double](repeating: 0, count: g2)
    var inIm = inRe
    var outRe = inRe
    var outIm = inRe
    let binOf = (0..<m).map { band.spectrumIndex(column: $0, bins: m) }
    let h2 = s.step * s.step
    for (r, n0) in rowIdx.enumerated() {
      for j in 0..<g2 {
        inRe[j] = 0
        inIm[j] = 0
      }
      for (j, wv) in w.enumerated() {
        let p = lo + j
        let idx = n0 + p
        if idx < 0 || idx >= n { continue }
        let slot = ((p % g2) + g2) % g2
        inRe[slot] = s.re[idx] * wv
        inIm[slot] = s.im[idx] * wv
      }
      dft.execute(sign, inputReal: inRe, inputImag: inIm, outputReal: &outRe, outputImag: &outIm)
      for c in 0..<m {
        let q = binOf[c]
        plane.values[r * m + c] = h2 * (outRe[q] * outRe[q] + outIm[q] * outIm[q])
      }
    }
    return plane
  }

  // MARK: Row helpers

  static func rowAxisFor(_ idx: [Int], samples n: Int, step: Double, origin: Double) -> Axis {
    guard let first = idx.first, let last = idx.last else { return Axis(start: origin, step: step, count: 0) }
    let k = idx.count
    let st = k > 1 ? Double(last - first) / Double(k - 1) * step : step
    return Axis(start: origin + Double(first) * step, step: st, count: k)
  }

  static func rowMeasureFor(_ idx: [Int], samples n: Int, step: Double) -> Double {
    guard !idx.isEmpty else { return step }
    return Double(n) / Double(idx.count) * step
  }

  /// The selected rows, spread evenly when rows × columns would exceed `maxPlaneValues`.
  static func boundedRows(_ selection: RowSelection, samples n: Int, columns m: Int) -> [Int] {
    let idx = selection.indices(samples: n)
    let cap = max(1, maxPlaneValues / max(m, 1))
    return idx.count <= cap ? idx : RowSelection.count(cap).indices(samples: n)
  }

  /// σ of a Gaussian window: non-finite or non-positive values become 1e-9 (a one-sample
  /// window) instead of NaN weights.
  static func windowSigma(_ sigma: Double) -> Double { sigma.isFinite ? max(sigma, 1e-9) : (sigma > 0 ? sigma : 1e-9) }

  /// The plane of a record without a usable step: no rows, no columns, finite measures.
  static func emptyPlane(kind: PlaneKind, signal s: Signal, band: Band?) -> Plane {
    let origin = s.origin.isFinite ? s.origin : 0
    return Plane(
      kind: kind, domain: s.domain, rowAxis: Axis(start: origin, step: 0, count: 0), columnAxis: Axis(start: 0, step: 0, count: 0),
      band: band ?? (s.domain == .time ? .positive : .centered), values: [], rowMeasure: 0, columnMeasure: 0, imaginaryResidual: 0,
      rowIndices: [], coversRecord: false)
  }
}

// MARK: - Live time–frequency views (Scope, Radio → Fourier, Spin FID, Patch)

nonisolated extension Phase {
  enum TimeFrequencyMode: String, Sendable, Hashable, Codable, CaseIterable {
    case spectrogram
    case wignerVille
    case pseudoWigner
    case smoothedPseudoWigner

    var title: String {
      switch self {
      case .spectrogram: "Spectrogram"
      case .wignerVille: "Wigner–Ville"
      case .pseudoWigner: "Pseudo-Wigner"
      case .smoothedPseudoWigner: "Smoothed pseudo-Wigner"
      }
    }
  }

  struct TimeFrequencyRequest: Sendable, Hashable, Codable {
    var mode: TimeFrequencyMode = .wignerVille
    /// Output rows (time) and columns (frequency). Columns should be a power of two.
    var rows: Int = 256
    var columns: Int = 256
    /// Pseudo / smoothed: Hann lag half-width in samples (default columns/2 − 1).
    var lagHalfWidth: Int?
    /// Smoothed: Hann time half-width in samples (default 2 × the row stride, at least 4).
    var smoothingHalfWidth: Int?
    /// Spectrogram: Hann window length in samples (default = columns).
    var spectrogramLength: Int?
    /// Wigner–Ville: largest lag DFT before falling back to a pseudo-Wigner (memory/time cap).
    var maxBins: Int = 16_384

    init(
      mode: TimeFrequencyMode = .wignerVille, rows: Int = 256, columns: Int = 256, lagHalfWidth: Int? = nil,
      smoothingHalfWidth: Int? = nil, spectrogramLength: Int? = nil, maxBins: Int = 16_384
    ) {
      self.mode = mode
      self.rows = rows
      self.columns = columns
      self.lagHalfWidth = lagHalfWidth
      self.smoothingHalfWidth = smoothingHalfWidth
      self.spectrogramLength = spectrogramLength
      self.maxBins = maxBins
    }
  }

  /// A time–frequency image with its edge strips: the measured marginals and their references.
  struct TimeFrequencyImage: Sendable, Hashable {
    var plane: Plane
    /// Σ_ν W dν per row (M1 of the image).
    var timeMarginal: [Double]
    /// |z|² at each row's sample (what M1 should be; equal for Wigner and pseudo-Wigner).
    var intensity: [Double]
    /// Σ_t W Δt per column (M2 of the image).
    var frequencyMarginal: [Double]
    /// |Z(ν)|² averaged onto the columns (what M2 approximates).
    var spectrum: [Double]
  }

  /// Time–frequency image of a real stream (the analytic signal, `.positive` band 0…fs/2).
  static func timeFrequency(
    real x: [Float], sampleRate: Double, origin: Double = 0, request: TimeFrequencyRequest = TimeFrequencyRequest()
  ) -> TimeFrequencyImage {
    let z = Signal.analytic(real: x, sampleRate: sampleRate, origin: origin)
    return timeFrequency(z, band: .positive, request: request)
  }

  /// Time–frequency image of a complex convention-(C) record (use `Signal.fromIQ` for I + jQ).
  /// With `oversample` (default) the record is interpolated 2× first, so the `.centered` band
  /// spans the original −fs/2 … fs/2 without the half-period alias (rule 2). Non-finite samples
  /// are zeroed before the interpolation, so one glitch cannot spread over the whole record.
  static func timeFrequency(
    complex z: Signal, oversample: Bool = true, request: TimeFrequencyRequest = TimeFrequencyRequest()
  ) -> TimeFrequencyImage {
    let clean = z.sanitized()
    return timeFrequency(oversample ? clean.oversampled2x() : clean, band: .centered, request: request)
  }

  /// The image for a record in a given band. A record without a positive, finite sample step
  /// (rate 0 or unknown, e.g. an irregular stream not yet resampled) gives an empty image (no
  /// rows, no columns) instead of NaN; non-finite samples count as 0 (as in `wigner`).
  static func timeFrequency(_ z: Signal, band: Band, request: TimeFrequencyRequest) -> TimeFrequencyImage {
    let z = z.sanitized()
    guard z.step.isFinite, z.step > 0 else {
      let kind: PlaneKind = request.mode == .spectrogram ? .spectrogram : .wigner
      return TimeFrequencyImage(
        plane: emptyPlane(kind: kind, signal: z, band: band), timeMarginal: [], intensity: [], frequencyMarginal: [], spectrum: [])
    }
    let n = z.count
    let cols = evenBins(request.columns)
    let rows = RowSelection.count(max(1, min(request.rows, max(1, n))))
    let stride = max(1, n / max(1, request.rows))
    var plane: Plane
    var bins = cols
    switch request.mode {
    case .wignerVille:
      var m = cols
      while m < n && m * 2 <= min(max(cols, request.maxBins), maxBins) { m *= 2 }
      bins = m
      plane = wigner(
        z, options: WignerOptions(bins: m, lag: .full, rows: rows, band: band, columnBinning: m / cols))
    case .pseudoWigner:
      plane = wigner(
        z, options: WignerOptions(bins: cols, lag: .hann(halfWidth: request.lagHalfWidth ?? (cols / 2 - 1)), rows: rows, band: band))
    case .smoothedPseudoWigner:
      let gHalf = request.smoothingHalfWidth ?? max(4, 2 * stride)
      plane = wigner(
        z,
        options: WignerOptions(
          bins: cols, lag: .hann(halfWidth: request.lagHalfWidth ?? (cols / 2 - 1)), smoothing: .hann(halfWidth: gHalf),
          rows: rows, band: band))
    case .spectrogram:
      plane = spectrogram(z, window: .hann(length: request.spectrogramLength ?? cols), bins: cols, rows: rows, band: band)
    }
    let reference = spectrum(z, bins: bins, band: band)
    let factor = plane.columns > 0 ? max(1, bins / plane.columns) : 1
    var spec = [Double](repeating: 0, count: plane.columns)
    for c in 0..<plane.columns {
      var acc = 0.0
      for j in 0..<factor { acc += reference.power[c * factor + j] }
      spec[c] = acc / Double(factor)
    }
    let inten = z.intensity()
    return TimeFrequencyImage(
      plane: plane, timeMarginal: plane.rowMarginal(), intensity: plane.rowIndices.map { inten[$0] },
      frequencyMarginal: plane.columnMarginal(), spectrum: spec)
  }
}
