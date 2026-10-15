import Foundation

/// Pure signal helpers for the Live sources (no UI, no sensors): resampling timestamped
/// samples onto a uniform grid, spectra of sensor streams through the RF engine's analyzer,
/// and the mains-aliasing arithmetic of the magnetometer probe (`gyre-integration.md` §4.3).
nonisolated enum LiveAnalysis {
  // MARK: Uniform resampling

  /// Linear interpolation of timestamped samples onto a uniform grid of `count` points at
  /// `rate` Hz that ends at the newest sample. Sensor timestamps jitter by a few percent, so
  /// an FFT must not assume the samples are evenly spaced. Returns fewer points when the
  /// record is shorter than `count / rate`; empty for fewer than two samples.
  static func resample(times: [Double], values: [Float], rate: Double, count: Int) -> [Float] {
    let n = min(times.count, values.count)
    guard n >= 2, rate > 0, count > 0, let last = times.last, let first = times.first, last > first else { return [] }
    let available = Int(((last - first) * rate).rounded(.down)) + 1
    let m = min(count, available)
    var out = [Float](repeating: 0, count: m)
    let start = last - Double(m - 1) / rate
    var j = 0
    for k in 0..<m {
      let t = start + Double(k) / rate
      while j < n - 2, times[j + 1] < t { j += 1 }
      let t0 = times[j]
      let t1 = times[j + 1]
      let span = t1 - t0
      let w = span > 0 ? min(1, max(0, (t - t0) / span)) : 0
      out[k] = values[j] + Float(w) * (values[j + 1] - values[j])
    }
    return out
  }

  // MARK: Spectra

  /// One-sided amplitude spectrum of a sensor record in dB re 1 unit: a sine of amplitude A
  /// reads 20·log₁₀ A. Several axes (x, y, z) add in power, so the result does not depend on
  /// how the phone is turned. The mean of each axis is removed first (the DC field).
  struct Spectrum: Sendable {
    /// dB per bin, bins 0 … N/2.
    var bins: [Float]
    /// Sample rate the record was resampled to (Hz).
    var sampleRate: Double
    /// FFT length.
    var count: Int
    /// Strongest bin above DC, parabolically refined.
    var peak: (frequency: Double, levelDB: Float)?
    /// Median bin level: the noise floor.
    var floorDB: Float

    var binWidth: Double { sampleRate / Double(count) }
    var nyquist: Double { sampleRate / 2 }

    /// Level of the strongest bin within ±`tolerance` Hz of `frequency`.
    func level(near frequency: Double, tolerance: Double) -> Float? {
      guard !bins.isEmpty, binWidth > 0 else { return nil }
      let lo = max(1, Int(((frequency - tolerance) / binWidth).rounded(.down)))
      let hi = min(bins.count - 1, Int(((frequency + tolerance) / binWidth).rounded(.up)))
      guard lo <= hi else { return nil }
      return bins[lo...hi].max()
    }
  }

  /// Spectrum of one or more axes, each resampled to `rate` over the newest `count` samples.
  /// Each axis loses its mean and, with `detrend`, its straight-line drift (the phone turning
  /// in Earth's field), so slow motion does not leak over the low bins. `peakAbove` (Hz) keeps
  /// the reported peak out of the drift region. nil until there are `count / 2` samples.
  static func spectrum(
    axes: [TimedSamples<Float>], rate: Double, count: Int, detrend: Bool = true, peakAbove: Double = 0
  ) -> Spectrum? {
    guard rate > 0, var analyzer = RF.SpectrumAnalyzer(count: count) else { return nil }
    var power: [Double]?
    for axis in axes {
      // Steady clocks are used as they are; jittery timestamps (over 1 %) are resampled onto a
      // uniform grid first (gyre-integration §4.3).
      var x: [Float] =
        intervalJitter(axis.times) < 0.01
        ? Array(axis.values.suffix(count))
        : resample(times: axis.times, values: axis.values, rate: rate, count: count)
      guard x.count >= count / 2 else { return nil }
      removeTrend(&x, linear: detrend)
      let db = analyzer.realSpectrumDB(x, scaling: .tone, floorDB: -160)
      if power == nil { power = [Double](repeating: 0, count: db.count) }
      for k in db.indices { power?[k] += pow(10, Double(db[k]) / 10) }
    }
    guard let power else { return nil }
    let bins = power.map { Float(10 * log10(max($0, 1e-16))) }
    let binWidth = rate / Double(count)
    let first = max(1, Int((peakAbove / binWidth).rounded(.up)))
    var peak: (frequency: Double, levelDB: Float)?
    if first < bins.count - 2,
      let p = RF.SpectrumAnalyzer.peak(ofOneSided: Array(bins[first...]), sampleRate: rate, count: count, ignoringDC: false)
    {
      peak = (p.frequency + Double(first) * binWidth, p.levelDB)
    }
    let sorted = bins.dropFirst().sorted()
    let floor = sorted.isEmpty ? -160 : sorted[sorted.count / 2]
    return Spectrum(bins: bins, sampleRate: rate, count: count, peak: peak, floorDB: floor)
  }

  /// Standard deviation of the sampling intervals relative to their mean (0.02 = ±2 %).
  static func intervalJitter(_ times: [Double]) -> Double {
    guard times.count > 2 else { return 0 }
    var sum = 0.0
    var sum2 = 0.0
    for i in 1..<times.count {
      let d = times[i] - times[i - 1]
      sum += d
      sum2 += d * d
    }
    let n = Double(times.count - 1)
    let mean = sum / n
    guard mean > 0 else { return 0 }
    return (max(0, sum2 / n - mean * mean)).squareRoot() / mean
  }

  /// Subtracts the mean (and, if `linear`, the least-squares straight line).
  static func removeTrend(_ x: inout [Float], linear: Bool) {
    let n = x.count
    guard n > 1 else { return }
    var sy = 0.0
    var sxy = 0.0
    for (i, v) in x.enumerated() {
      sy += Double(v)
      sxy += Double(i) * Double(v)
    }
    let nn = Double(n)
    let mx = (nn - 1) / 2
    let my = sy / nn
    var slope = 0.0
    if linear {
      let sxx = nn * (nn * nn - 1) / 12
      slope = (sxy - nn * mx * my) / sxx
    }
    for i in 0..<n { x[i] -= Float(my + slope * (Double(i) - mx)) }
  }

  // MARK: Mains aliasing

  /// One mains line as a sampled sensor sees it.
  struct AliasLine: Hashable, Sendable, Identifiable {
    /// The true frequency (Hz): the mains fundamental or a harmonic.
    var frequency: Double
    /// Where it lands after sampling at fs: |f − fs·round(f/fs)| (`rf-physics.md` G.3).
    var alias: Double
    var harmonic: Int
    var id: String { "\(frequency)" }
    var isFolded: Bool { abs(alias - frequency) > 1e-9 }
  }

  /// The fundamental and second harmonic of `mains` (50 or 60 Hz) folded by sampling at `fs`.
  /// 60 Hz at 99.8 Hz → 39.8 Hz; 120 Hz → 20.2 Hz.
  static func mainsLines(mains: Double, sampleRate fs: Double, harmonics: Int = 2) -> [AliasLine] {
    guard fs > 0 else { return [] }
    return (1...max(1, harmonics)).map { k in
      let f = mains * Double(k)
      return AliasLine(frequency: f, alias: RF.DSP.aliasFrequency(f, sampleRate: fs), harmonic: k)
    }
  }

  /// Which mains frequency (50 or 60 Hz) a magnetometer spectrum shows, if any: the folded
  /// fundamental must stand `margin` dB above the noise floor. nil when neither does.
  static func detectMains(in spectrum: Spectrum, margin: Float = 12) -> Double? {
    var best: (Double, Float)?
    for mains in [60.0, 50.0] {
      let alias = RF.DSP.aliasFrequency(mains, sampleRate: spectrum.sampleRate)
      // A line within two bins of DC or of Nyquist cannot be told apart from drift.
      guard alias > 2 * spectrum.binWidth, alias < spectrum.nyquist - spectrum.binWidth else { continue }
      guard let level = spectrum.level(near: alias, tolerance: 2 * spectrum.binWidth) else { continue }
      let excess = level - spectrum.floorDB
      if excess >= margin, excess > (best?.1 ?? -.infinity) { best = (mains, excess) }
    }
    return best?.0
  }

  // MARK: Audio

  /// The loudest frequency of an audio block (Hann, 4096 points by default) and its level in
  /// dBFS, or nil for silence (below −90 dBFS) or too few samples.
  static func loudest(_ samples: [Float], sampleRate: Double, count: Int = 4096, analyzer: inout RF.SpectrumAnalyzer)
    -> (frequency: Double, levelDB: Float)?
  {
    guard samples.count >= count / 2, sampleRate > 0 else { return nil }
    let db = analyzer.realSpectrumDB(Array(samples.suffix(count)), scaling: .tone, floorDB: -160)
    guard let peak = RF.SpectrumAnalyzer.peak(ofOneSided: db, sampleRate: sampleRate, count: count), peak.levelDB > -90
    else { return nil }
    return (peak.frequency, peak.levelDB)
  }

  /// RMS level in dBFS of a block (−∞ guarded at −120).
  static func levelDBFS(_ block: ArraySlice<Float>) -> Float {
    guard !block.isEmpty else { return -120 }
    var sum: Double = 0
    for v in block { sum += Double(v) * Double(v) }
    let rms = (sum / Double(block.count)).squareRoot()
    return Float(20 * log10(max(rms, 1e-6)))
  }
}
