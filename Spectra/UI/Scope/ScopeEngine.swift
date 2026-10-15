import Foundation

/// The oscilloscope's pure maths (SPEC-features §3b): trigger detection with hysteresis and
/// holdoff, min/max decimation that keeps peaks, roll and YT traces, XY pairing by
/// timestamp, measurements (zero-crossing and FFT-peak frequency, period, Pk-Pk, RMS, mean,
/// min, max), the math channel (A+B, A−B, A·B, |vector|, d/dt, ∫dt, high-pass), coupling
/// filters for irregular sampling, 1-2-5 scale sequences, stream resolution and CSV.
///
/// Everything here is `nonisolated` and value-typed, so `ScopeTests` and any thread can call
/// it. Spectra's engines supply the physics it relies on: `RF.SpectrumAnalyzer` (FFT, Hann,
/// parabolic peak), `RF.DSP` (windows, alias frequency) and `Phase.timeFrequency` (the
/// time–frequency modes, called by `ScopeModel`). Samples keep their sensors' own
/// timestamps throughout; nothing assumes a uniform rate unless it resamples explicitly.
nonisolated enum ScopeEngine {
  /// Graticule: 10 horizontal by 8 vertical divisions.
  static let divisionsX = 10
  static let divisionsY = 8

  // MARK: - 1-2-5 sequences

  /// Every 1-2-5 value in `lo...hi` (inclusive, tolerant of rounding).
  static func sequence125(from lo: Double, to hi: Double) -> [Double] {
    guard lo > 0, hi >= lo, lo.isFinite, hi.isFinite else { return [] }
    var out: [Double] = []
    var decade = Int(floor(log10(lo))) - 1
    while decade < 40 {
      for m in [1.0, 2, 5] {
        let v = clean(m * pow(10, Double(decade)))
        if v > hi * (1 + 1e-9) { return out }
        if v >= lo * (1 - 1e-9) { out.append(v) }
      }
      decade += 1
    }
    return out
  }

  /// The smallest 1-2-5 value ≥ `x` (x > 0).
  static func nice125(atLeast x: Double) -> Double {
    guard x.isFinite, x > 0 else { return 1 }
    let decade = floor(log10(x))
    for d in [decade - 1, decade, decade + 1] {
      for m in [1.0, 2, 5] {
        let v = clean(m * pow(10, d))
        if v >= x * (1 - 1e-9) { return v }
      }
    }
    return clean(pow(10, decade + 1))
  }

  /// Removes binary noise from a decimal 1-2-5 value (0.30000000000000004 → 0.3).
  static func clean(_ v: Double) -> Double {
    Double(String(format: "%.12g", v)) ?? v
  }

  // MARK: - Timebase

  /// The timebase switch positions, 10 µs/div … 10 s/div.
  static let timebases: [Double] = sequence125(from: 10e-6, to: 10)

  /// Roll mode takes over at and above this timebase (seismograph style).
  static let rollThreshold = 0.5

  /// The fastest timebase a stream can show honestly: at least one sample per division
  /// (s/div ≥ 1/rate), snapped up to the 1-2-5 sequence. Irregular streams without a measured
  /// rate get 100 ms/div.
  static func minimumTimebase(sampleRate: Double?) -> Double {
    guard let r = sampleRate, r > 0, r.isFinite else { return 0.1 }
    let need = 1 / r
    return timebases.first { $0 >= need * (1 - 1e-9) } ?? timebases[timebases.count - 1]
  }

  /// The slowest timebase whose 10-division window fits `history` seconds of samples.
  static func maximumTimebase(history: Double) -> Double {
    guard history.isFinite, history > 0 else { return timebases[timebases.count - 1] }
    let cap = history / Double(divisionsX)
    return timebases.last { $0 <= cap * (1 + 1e-9) } ?? timebases[0]
  }

  /// Seconds of history the scope can show for a stream: its ring, or the scope's own cache
  /// (up to 120 s or 200,000 samples), whichever is longer.
  static func history(ringCapacity: Int, rate: Double?) -> Double {
    guard let r = rate, r > 0, r.isFinite else { return 120 }
    let ring = Double(ringCapacity) / r
    return max(ring, min(120, 200_000 / r))
  }

  /// Allowed timebases for a set of streams: the fastest stream sets the floor (one sample
  /// per division), the longest history the ceiling.
  static func timebaseRange(rates: [Double?], histories: [Double]) -> ClosedRange<Double> {
    let floors = rates.map { minimumTimebase(sampleRate: $0) }
    let lo = floors.min() ?? timebases[0]
    let hi = max(lo, maximumTimebase(history: histories.max() ?? 30))
    return lo...hi
  }

  /// Snaps a timebase onto the switch and into `range`.
  static func clampTimebase(_ t: Double, to range: ClosedRange<Double>) -> Double {
    let allowed = timebases.filter { $0 >= range.lowerBound * (1 - 1e-9) && $0 <= range.upperBound * (1 + 1e-9) }
    guard !allowed.isEmpty else { return range.lowerBound }
    return allowed.min { abs(log($0 / max(t, 1e-12))) < abs(log($1 / max(t, 1e-12))) } ?? allowed[0]
  }

  // MARK: - Vertical scale

  /// Units-per-division switch positions for a unit (1-2-5).
  static func scales(unit: String) -> [Double] {
    let r = scaleRange(unit: unit)
    return sequence125(from: r.lowerBound, to: r.upperBound)
  }

  /// A sensible units/div range for each unit the app publishes.
  static func scaleRange(unit: String) -> ClosedRange<Double> {
    switch unit {
    case "µT", "uT": 0.001...500
    case "g": 0.000_1...5
    case "rad/s": 0.000_5...20
    case "°", "deg": 0.01...200
    case "dBm", "dB", "dBFS": 0.1...50
    case "Pa": 0.01...20_000
    case "hPa": 0.000_1...200
    case "m": 0.001...1000
    case "FS": 0.000_01...1
    case "lux": 0.01...20_000
    case "K": 1...5000
    case "ms": 0.01...2000
    case "%": 0.01...50
    case "level": 0.1...5
    default: 0.000_001...1_000_000
    }
  }

  /// Level units in decibels (dBm, dBFS, dB): a difference or spread of two readings is in dB
  /// (two RSSI readings 20 dB apart, not "20 dBm"), and their average power is the mean of
  /// 10^(x/10), not an RMS of the numbers (which for −50 dBm readings would read "+50 dBm").
  static func isLogarithmic(_ unit: String) -> Bool { unit.hasPrefix("dB") }

  /// The unit of a difference between two values in `unit`: dB for decibel levels, else the unit.
  static func differenceUnit(_ unit: String) -> String { isLogarithmic(unit) ? "dB" : unit }

  /// Mean power of decibel readings, in their own unit: 10·log₁₀(mean 10^(x/10)).
  static func powerMean(_ values: [Float]) -> Double? {
    var sum = 0.0
    var count = 0
    for v in values where v.isFinite {
      sum += pow(10, Double(v) / 10)
      count += 1
    }
    guard count > 0, sum > 0 else { return nil }
    return 10 * log10(sum / Double(count))
  }

  /// Units of step streams (link quality, battery or thermal state, events): their value holds
  /// until the next sample, so the scope draws them sample-and-hold rather than as ramps.
  static func isStepUnit(_ unit: String) -> Bool {
    ["level", "state", "event"].contains(unit.lowercased())
  }

  /// The nearest switch position to `value`.
  static func snapScale(_ value: Double, unit: String) -> Double {
    let list = scales(unit: unit)
    guard !list.isEmpty, value.isFinite, value > 0 else { return list.first ?? 1 }
    return list.min { abs(log($0 / value)) < abs(log($1 / value)) } ?? list[0]
  }

  /// Auto-scale: a 1-2-5 units/div so the data spans about `divisions` of the 8, centred.
  static func autoScale(minimum: Double, maximum: Double, unit: String, divisions: Double = 6)
    -> (unitsPerDiv: Double, reference: Double)
  {
    guard minimum.isFinite, maximum.isFinite, maximum >= minimum else { return (snapScale(1, unit: unit), 0) }
    let mid = (minimum + maximum) / 2
    let span = maximum - minimum
    let floorSpan = max(abs(mid) * 1e-4, scaleRange(unit: unit).lowerBound)
    let want = max(span, floorSpan) / divisions
    let list = scales(unit: unit)
    let upd = list.first { $0 >= want * (1 - 1e-9) } ?? list.last ?? nice125(atLeast: want)
    return (upd, mid)
  }

  // MARK: - Lookup helpers

  /// First index with `times[i] >= t` (times ascending).
  static func lowerBound(_ times: [Double], _ t: Double) -> Int {
    var lo = 0
    var hi = times.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if times[mid] < t { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// First index with `times[i] > t` (times ascending).
  static func upperBound(_ times: [Double], _ t: Double) -> Int {
    var lo = 0
    var hi = times.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if times[mid] <= t { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  /// The series' value at time `t`: linear interpolation between neighbours, or the last
  /// sample at or before `t` when `hold` (sample-and-hold for irregular streams). Nil outside
  /// the samples' span widened by `tolerance` (and, when holding, before the first sample).
  static func value(at t: Double, values: [Float], times: [Double], hold: Bool, tolerance: Double = 0) -> Float? {
    let n = min(values.count, times.count)
    guard n > 0, t.isFinite else { return nil }
    if t < times[0] - tolerance { return nil }
    if !hold, t > times[n - 1] + tolerance { return nil }
    let j = upperBound(times, t)  // first sample after t
    if j == 0 { return values[0] }
    if j >= n { return values[n - 1] }
    if hold { return values[j - 1] }
    let t0 = times[j - 1]
    let t1 = times[j]
    guard t1 > t0 else { return values[j] }
    let f = Float((t - t0) / (t1 - t0))
    return values[j - 1] + (values[j] - values[j - 1]) * f
  }

  // MARK: - Trigger

  enum Slope: String, Codable, Sendable, CaseIterable, Identifiable {
    case rising, falling
    var id: String { rawValue }
    var title: String { self == .rising ? "Rising" : "Falling" }
    var symbol: String { self == .rising ? "arrow.up.right" : "arrow.down.right" }
  }

  /// Times at which the signal crosses `level` in the `slope` direction (interpolated between
  /// samples, so a steady tone stands still on screen).
  ///
  /// - Hysteresis: after a trigger the signal must go back beyond `level ∓ hysteresis` before
  ///   the next edge counts, so noise riding on an edge cannot re-trigger.
  /// - Holdoff: an accepted trigger blocks the next for `holdoff` seconds; an edge inside the
  ///   holdoff disarms like any other (it needs a fresh edge afterwards).
  /// - `notBefore`: edges earlier than this are not accepted (the model passes the previous
  ///   sweep's trigger + sweep + holdoff).
  /// - `range`: only these indices are searched (the model passes the new stretch of a whole
  ///   track instead of copying it every frame).
  static func triggerTimes(
    values: [Float], times: [Double], level: Double, slope: Slope, hysteresis: Double = 0, holdoff: Double = 0,
    notBefore: Double = -.infinity, range: Range<Int>? = nil
  ) -> [Double] {
    let n = min(values.count, times.count)
    let r = (range ?? 0..<n).clamped(to: 0..<n)
    guard r.count > 1, level.isFinite else { return [] }
    let s: Double = slope == .rising ? 1 : -1
    let L = level * s
    let h = hysteresis.isFinite ? max(0, hysteresis) : 0
    let hold = holdoff.isFinite ? max(0, holdoff) : 0
    var armed = false
    var last = -Double.infinity
    var out: [Double] = []
    for i in r {
      let v = Double(values[i]) * s
      guard v.isFinite else {
        armed = false
        continue
      }
      if v < L - h || (h == 0 && v < L) {
        armed = true
      } else if armed, v >= L, i > r.lowerBound {
        armed = false
        let v0 = Double(values[i - 1]) * s
        let t0 = times[i - 1]
        let t1 = times[i]
        let frac = v != v0 ? min(1, max(0, (L - v0) / (v - v0))) : 1
        let t = t0 + frac * (t1 - t0)
        if t >= notBefore, t - last >= hold {
          out.append(t)
          last = t
        }
      }
    }
    return out
  }

  // MARK: - Traces and decimation

  /// One pixel column of a decimated trace.
  struct Column: Sendable, Equatable {
    var minimum: Float
    var maximum: Float
    /// Whether the minimum came before the maximum in time.
    var minimumFirst: Bool
    var count: Int
  }

  /// Per-column min/max of the samples inside `window` (nil for empty columns). Every sample
  /// lands in exactly one column, so no peak is lost however far the trace is decimated.
  static func decimate(values: [Float], times: [Double], window: ClosedRange<Double>, columns: Int) -> [Column?] {
    var out: [Column?] = []
    decimate(values: values, times: times, window: window, columns: columns, into: &out)
    return out
  }

  /// `decimate` into a reused buffer (the per-frame drawing keeps one, so a frame allocates nothing).
  static func decimate(values: [Float], times: [Double], window: ClosedRange<Double>, columns: Int, into out: inout [Column?]) {
    let n = min(values.count, times.count)
    let cols = max(1, columns)
    out.removeAll(keepingCapacity: true)
    out.append(contentsOf: repeatElement(Column?.none, count: cols))
    let span = window.upperBound - window.lowerBound
    guard n > 0, span > 0 else { return }
    let start = lowerBound(times, window.lowerBound)
    let end = upperBound(times, window.upperBound)
    guard start < end else { return }
    for i in start..<end {
      let v = values[i]
      guard v.isFinite else { continue }
      let c = min(cols - 1, max(0, Int((times[i] - window.lowerBound) / span * Double(cols))))
      if var col = out[c] {
        if v < col.minimum {
          col.minimum = v
          col.minimumFirst = false
        }
        if v > col.maximum {
          col.maximum = v
          col.minimumFirst = true
        }
        col.count += 1
        out[c] = col
      } else {
        out[c] = Column(minimum: v, maximum: v, minimumFirst: true, count: 1)
      }
    }
  }

  /// A display trace of the samples in `window`: x = fraction 0…1 across the window, y =
  /// value. With more than two samples per column it is the per-column min/max in time order
  /// (the envelope fills, peaks survive); otherwise the samples themselves, joined by lines,
  /// or by sample-and-hold steps for irregular streams (`hold`), clipped at the window edges.
  /// `holdUntil` extends the last held value to that time (an irregular stream's "now").
  static func trace(
    values: [Float], times: [Double], window: ClosedRange<Double>, columns: Int, hold: Bool = false,
    holdUntil: Double? = nil
  ) -> [SIMD2<Float>] {
    var out: [SIMD2<Float>] = []
    var scratch: [Column?] = []
    trace(values: values, times: times, window: window, columns: columns, hold: hold, holdUntil: holdUntil, into: &out, columnScratch: &scratch)
    return out
  }

  /// `trace` into reused buffers (`out` is replaced; `columnScratch` holds the decimation), so
  /// the per-frame drawing allocates nothing once the buffers have grown.
  static func trace(
    values: [Float], times: [Double], window: ClosedRange<Double>, columns: Int, hold: Bool = false,
    holdUntil: Double? = nil, into out: inout [SIMD2<Float>], columnScratch: inout [Column?]
  ) {
    out.removeAll(keepingCapacity: true)
    let n = min(values.count, times.count)
    let span = window.upperBound - window.lowerBound
    guard n > 0, span > 0 else { return }
    let lo = window.lowerBound
    func x(_ t: Double) -> Float { Float((t - lo) / span) }
    let start = lowerBound(times, window.lowerBound)
    let end = upperBound(times, window.upperBound)
    let inside = end - start
    let cols = max(1, columns)
    if inside > cols * 2 {
      decimate(values: values, times: times, window: window, columns: cols, into: &columnScratch)
      out.reserveCapacity(cols * 2)
      for (c, column) in columnScratch.enumerated() {
        guard let column else { continue }
        let xc = (Float(c) + 0.5) / Float(cols)
        if column.minimum == column.maximum {
          out.append(SIMD2(xc, column.minimum))
        } else if column.minimumFirst {
          out.append(SIMD2(xc, column.minimum))
          out.append(SIMD2(xc, column.maximum))
        } else {
          out.append(SIMD2(xc, column.maximum))
          out.append(SIMD2(xc, column.minimum))
        }
      }
      return
    }
    out.reserveCapacity(inside * (hold ? 2 : 1) + 4)
    // Leading edge: the sample before the window.
    if start > 0, values[start - 1].isFinite {
      if hold {
        out.append(SIMD2(0, values[start - 1]))
      } else if start < n {
        let t0 = times[start - 1]
        let t1 = times[start]
        if t1 > t0 {
          let f = Float((lo - t0) / (t1 - t0))
          out.append(SIMD2(0, values[start - 1] + (values[start] - values[start - 1]) * f))
        }
      }
    }
    for i in start..<end {
      let v = values[i]
      guard v.isFinite else { continue }
      if hold, let previous = out.last {
        out.append(SIMD2(x(times[i]), previous.y))
      }
      out.append(SIMD2(x(times[i]), v))
    }
    // Trailing edge: interpolate to the window end, or hold.
    if hold {
      if let last = out.last {
        let until = min(window.upperBound, holdUntil ?? (end < n ? times[end] : window.lowerBound))
        if until > (end > start ? times[end - 1] : lo) { out.append(SIMD2(min(1, x(until)), last.y)) }
      }
    } else if end < n, end > 0, values[end].isFinite, values[end - 1].isFinite {
      let t0 = times[end - 1]
      let t1 = times[end]
      if t1 > t0, t0 < window.upperBound {
        let f = Float((window.upperBound - t0) / (t1 - t0))
        out.append(SIMD2(1, values[end - 1] + (values[end] - values[end - 1]) * f))
      }
    }
  }

  /// Roll (seismograph) trace: the newest `span` seconds ending at `end` (usually now), the
  /// newest sample at the right edge, everything in time order.
  static func rollTrace(
    values: [Float], times: [Double], end: Double, span: Double, columns: Int, hold: Bool = false
  ) -> [SIMD2<Float>] {
    trace(
      values: values, times: times, window: (end - span)...end, columns: columns, hold: hold,
      holdUntil: hold ? end : nil)
  }

  /// `rollTrace` into reused buffers (see `trace(…into:columnScratch:)`).
  static func rollTrace(
    values: [Float], times: [Double], end: Double, span: Double, columns: Int, hold: Bool = false,
    into out: inout [SIMD2<Float>], columnScratch: inout [Column?]
  ) {
    trace(
      values: values, times: times, window: (end - span)...end, columns: columns, hold: hold,
      holdUntil: hold ? end : nil, into: &out, columnScratch: &columnScratch)
  }

  // MARK: - XY

  /// XY pairs by timestamp: each X sample inside `window` is paired with Y at the same
  /// instant (interpolated, or held for an irregular Y). X samples where Y has no data within
  /// `tolerance` are dropped, so two sensors with different clocks never pair stale values.
  static func pairXY(
    x: (values: [Float], times: [Double]), y: (values: [Float], times: [Double]), window: ClosedRange<Double>,
    tolerance: Double, holdY: Bool = false
  ) -> [SIMD2<Float>] {
    var out: [SIMD2<Float>] = []
    pairXY(x: x, y: y, window: window, tolerance: tolerance, holdY: holdY, into: &out)
    return out
  }

  /// `pairXY` into a reused buffer (`out` is replaced).
  static func pairXY(
    x: (values: [Float], times: [Double]), y: (values: [Float], times: [Double]), window: ClosedRange<Double>,
    tolerance: Double, holdY: Bool = false, into out: inout [SIMD2<Float>]
  ) {
    out.removeAll(keepingCapacity: true)
    let n = min(x.values.count, x.times.count)
    guard n > 0, !y.values.isEmpty else { return }
    let start = lowerBound(x.times, window.lowerBound)
    let end = upperBound(x.times, window.upperBound)
    guard start < end else { return }
    out.reserveCapacity(end - start)
    for i in start..<end {
      let t = x.times[i]
      let xv = x.values[i]
      guard xv.isFinite else { continue }
      if !holdY {
        // Require a Y sample within tolerance on at least one side.
        let j = upperBound(y.times, t)
        let before = j > 0 ? t - y.times[j - 1] : .infinity
        let after = j < y.times.count ? y.times[j] - t : .infinity
        guard min(before, after) <= tolerance else { continue }
      }
      guard let yv = value(at: t, values: y.values, times: y.times, hold: holdY, tolerance: tolerance), yv.isFinite
      else { continue }
      out.append(SIMD2(xv, yv))
    }
  }

  // MARK: - Measurements

  /// Automatic measurements of one channel's visible window.
  struct Measurements: Sendable, Equatable {
    var count = 0
    var minimum: Double?
    var maximum: Double?
    var mean: Double?
    /// True RMS including DC.
    var rms: Double?
    /// RMS of the AC part (standard deviation).
    var acRMS: Double?
    var peakToPeak: Double?
    /// Frequency from rising mean-crossings (interpolated, with 5 % hysteresis).
    var frequencyZeroCrossing: Double?
    /// Frequency of the strongest FFT line (Hann, 4× zero padding, parabolic peak).
    var frequencyFFT: Double?
    /// 1/f (zero-crossing first, FFT otherwise).
    var period: Double?
  }

  /// Keeps one `RF.SpectrumAnalyzer` per FFT size for the measurements' FFT peak, so a model
  /// that measures several channels five times a second does not rebuild vDSP setups each time.
  struct PeakAnalyzers: Sendable {
    fileprivate var analyzers: [Int: RF.SpectrumAnalyzer] = [:]
    init() {}
  }

  /// Every measurement over `values` (taken at `times`). `sampleRate` (measured, Hz) enables
  /// the FFT peak; irregular streams pass nil and get no FFT frequency.
  static func measure(values: [Float], times: [Double], sampleRate: Double?) -> Measurements {
    var analyzers = PeakAnalyzers()
    return measure(values: values, times: times, sampleRate: sampleRate, analyzers: &analyzers)
  }

  /// `measure` with a reusable analyzer cache (the model's per-refresh path).
  static func measure(values: [Float], times: [Double], sampleRate: Double?, analyzers: inout PeakAnalyzers) -> Measurements {
    var m = Measurements()
    let n = min(values.count, times.count)
    var lo = Double.infinity
    var hi = -Double.infinity
    var sum = 0.0
    var sumSquares = 0.0
    var count = 0
    for i in 0..<n {
      let v = Double(values[i])
      guard v.isFinite else { continue }
      lo = min(lo, v)
      hi = max(hi, v)
      sum += v
      sumSquares += v * v
      count += 1
    }
    m.count = count
    guard count > 0 else { return m }
    let mean = sum / Double(count)
    m.minimum = lo
    m.maximum = hi
    m.mean = mean
    m.peakToPeak = hi - lo
    m.rms = (sumSquares / Double(count)).squareRoot()
    m.acRMS = max(0, sumSquares / Double(count) - mean * mean).squareRoot()
    if hi > lo {
      m.frequencyZeroCrossing = zeroCrossingFrequency(values: Array(values[0..<n]), times: Array(times[0..<n]))
      if let fs = sampleRate {
        m.frequencyFFT = fftPeakFrequency(values: Array(values[0..<n]), sampleRate: fs, analyzers: &analyzers)
      }
    }
    if let f = m.frequencyZeroCrossing ?? m.frequencyFFT, f > 0 { m.period = 1 / f }
    return m
  }

  /// Frequency from rising crossings of the mean (with 5 % of Pk-Pk hysteresis), using the
  /// interpolated crossing times: (crossings − 1) / (last − first). Needs at least two.
  static func zeroCrossingFrequency(values: [Float], times: [Double], hysteresisFraction: Double = 0.05) -> Double? {
    let finite = values.filter(\.isFinite)
    guard finite.count > 2, let lo = finite.min(), let hi = finite.max(), hi > lo else { return nil }
    let mean = finite.reduce(0.0) { $0 + Double($1) } / Double(finite.count)
    let crossings = triggerTimes(
      values: values, times: times, level: mean, slope: .rising, hysteresis: Double(hi - lo) * hysteresisFraction)
    guard crossings.count >= 2, let first = crossings.first, let last = crossings.last, last > first else { return nil }
    return Double(crossings.count - 1) / (last - first)
  }

  /// Frequency of the strongest line: the newest ≤ 16,384 samples, mean removed, Hann window,
  /// zero-padded 4× and transformed with `RF.SpectrumAnalyzer`; the peak bin is refined by
  /// `RF.SpectrumAnalyzer.peak` (parabolic interpolation of the dB values).
  static func fftPeakFrequency(values: [Float], sampleRate: Double) -> Double? {
    var analyzers = PeakAnalyzers()
    return fftPeakFrequency(values: values, sampleRate: sampleRate, analyzers: &analyzers)
  }

  /// `fftPeakFrequency` with a reusable analyzer cache.
  static func fftPeakFrequency(values: [Float], sampleRate: Double, analyzers cache: inout PeakAnalyzers) -> Double? {
    guard sampleRate.isFinite, sampleRate > 0 else { return nil }
    let finite = values.suffix(16_384).map { $0.isFinite ? $0 : 0 }
    let m = finite.count
    guard m >= 16 else { return nil }
    let mean = finite.reduce(0.0) { $0 + Double($1) } / Double(m)
    let window = RF.DSP.window(.hann, count: m)
    var x = [Float](repeating: 0, count: m)
    for i in 0..<m { x[i] = (finite[i] - Float(mean)) * window[i] }
    let size = min(65_536, RF.DSP.nextPowerOfTwo(m) * 4)
    if cache.analyzers[size] == nil { cache.analyzers[size] = RF.SpectrumAnalyzer(count: size, window: .rectangular) }
    guard var analyzer = cache.analyzers[size] else { return nil }
    let db = analyzer.realSpectrumDB(x)
    cache.analyzers[size] = analyzer
    guard let peak = RF.SpectrumAnalyzer.peak(ofOneSided: db, sampleRate: sampleRate, count: size) else { return nil }
    return peak.frequency > 0 ? peak.frequency : nil
  }

  // MARK: - Spectrum (FFT mode)

  /// One-sided amplitude spectrum for display.
  struct Spectrum: Sendable, Equatable {
    /// dB re 1 stream unit: a sine of amplitude A at a bin centre reads 20·log₁₀A.
    var db: [Float]
    /// Bin spacing f_s/N (Hz).
    var binWidth: Double
    var count: Int
    var sampleRate: Double
    var peakFrequency: Double?
    var peakDB: Float?

    var nyquist: Double { sampleRate / 2 }
  }

  /// Caches one `RF.SpectrumAnalyzer` per FFT size (they own vDSP setups and buffers).
  struct SpectrumCache: Sendable {
    private var analyzers: [Int: RF.SpectrumAnalyzer] = [:]

    init() {}

    /// The spectrum of the newest power-of-two block (64…16,384 samples) of `values`,
    /// Hann-windowed (`.tone` scaling); `removeMean` drops the DC line first.
    mutating func spectrum(values: [Float], sampleRate: Double, removeMean: Bool) -> Spectrum? {
      guard sampleRate.isFinite, sampleRate > 0, values.count >= 64 else { return nil }
      var size = 64
      while size * 2 <= values.count, size < 16_384 { size *= 2 }
      var block = values.suffix(size).map { $0.isFinite ? $0 : 0 }
      if removeMean {
        let mean = block.reduce(0, +) / Float(size)
        for i in block.indices { block[i] -= mean }
      }
      if analyzers[size] == nil { analyzers[size] = RF.SpectrumAnalyzer(count: size, window: .hann) }
      guard var analyzer = analyzers[size] else { return nil }
      let db = analyzer.realSpectrumDB(block, scaling: .tone, floorDB: -160)
      analyzers[size] = analyzer
      let peak = RF.SpectrumAnalyzer.peak(ofOneSided: db, sampleRate: sampleRate, count: size)
      return Spectrum(
        db: db, binWidth: sampleRate / Double(size), count: size, sampleRate: sampleRate, peakFrequency: peak?.frequency,
        peakDB: peak?.levelDB)
    }
  }

  // MARK: - Resampling

  /// Uniform samples at `rate` over `window` (sample-and-hold or linear), for the FFT and
  /// time–frequency views of irregular streams. Times before the first sample are skipped.
  static func resample(
    values: [Float], times: [Double], rate: Double, window: ClosedRange<Double>, hold: Bool, maxCount: Int = 65_536
  ) -> (values: [Float], start: Double) {
    guard rate > 0, rate.isFinite, !values.isEmpty, window.upperBound > window.lowerBound else { return ([], 0) }
    let start = max(window.lowerBound, times.first ?? window.lowerBound)
    let count = min(maxCount, Int(((window.upperBound - start) * rate).rounded(.down)) + 1)
    guard count > 1 else { return ([], start) }
    var out = [Float]()
    out.reserveCapacity(count)
    for k in 0..<count {
      let t = start + Double(k) / rate
      out.append(value(at: t, values: values, times: times, hold: hold, tolerance: .infinity) ?? 0)
    }
    return (out, start)
  }

  /// Averages blocks of `factor` samples (a boxcar anti-alias filter, then keeps one in
  /// `factor`), for time–frequency records longer than the engine's cap.
  static func boxcarDecimate(_ values: [Float], factor: Int) -> [Float] {
    guard factor > 1 else { return values }
    let n = values.count / factor
    var out = [Float](repeating: 0, count: n)
    for k in 0..<n {
      var acc: Float = 0
      for j in 0..<factor { acc += values[k * factor + j] }
      out[k] = acc / Float(factor)
    }
    return out
  }

  // MARK: - Filters for irregular sampling

  /// A one-pole high-pass that uses each sample's own time step, so it works on irregular
  /// streams: y[n] = a·(y[n−1] + x[n] − x[n−1]), a = RC/(RC + Δt), RC = 1/(2π f_c).
  /// The first sample outputs 0 (no start-up step).
  struct OnePoleHighPass: Sendable, Equatable {
    var cornerHz: Double
    private var x1: Double?
    private var y1 = 0.0
    private var t1 = 0.0

    init(cornerHz: Double) { self.cornerHz = cornerHz }

    mutating func reset() { x1 = nil }

    mutating func process(_ x: Double, at t: Double) -> Double {
      guard x.isFinite else { return y1 }
      guard let previous = x1 else {
        x1 = x
        t1 = t
        y1 = 0
        return 0
      }
      let dt = max(0, t - t1)
      let rc = 1 / (2 * Double.pi * max(cornerHz, 1e-9))
      let a = rc / (rc + dt)
      let y = a * (y1 + x - previous)
      x1 = x
      y1 = y.isFinite ? y : 0
      t1 = t
      return y1
    }
  }

  /// "No gravity" without a gravity stream: a 0.25 Hz high-pass (tilting the phone is slower).
  static let gravityCorner = 0.25
  /// "No Earth field": a 0.01 Hz high-pass (a 16 s baseline), so the steady ~50 µT goes while
  /// mains hum and a magnet approaching over a few seconds stay.
  static let earthFieldCorner = 0.01

  /// Coupling corner for "AC": f_s/50, kept within 0.05…10 Hz (mag and motion at 100 Hz →
  /// 2 Hz, above the phone's sway, so mains hum and vibration stand out; audio → 10 Hz, like a
  /// bench scope's AC input; barometer → 0.05 Hz).
  static func acCorner(sampleRate: Double?) -> Double {
    guard let r = sampleRate, r > 0, r.isFinite else { return 0.05 }
    return min(10, max(0.05, r / 50))
  }

  // MARK: - Math

  enum MathOperation: String, Codable, Sendable, CaseIterable, Identifiable {
    case sum, difference, product, magnitude, derivative, integral, highPass

    var id: String { rawValue }

    var title: String {
      switch self {
      case .sum: "A + B"
      case .difference: "A − B"
      case .product: "A × B"
      case .magnitude: "|vector|"
      case .derivative: "d/dt"
      case .integral: "∫ dt"
      case .highPass: "High-pass"
      }
    }

    /// How many sources the operation reads (|vector| uses A, B and C).
    var inputs: Int {
      switch self {
      case .sum, .difference, .product: 2
      case .magnitude: 3
      case .derivative, .integral, .highPass: 1
      }
    }

    /// The result's unit from A's and B's units.
    func unit(_ a: String, _ b: String) -> String {
      switch self {
      case .sum, .difference, .magnitude, .highPass: a
      case .product: a == b ? "\(a)²" : "\(a)·\(b)"
      case .derivative: "\(a)/s"
      case .integral: "\(a)·s"
      }
    }

    /// The formula as a label ("√(A² + B² + C²)").
    var formula: String {
      switch self {
      case .sum: "A + B"
      case .difference: "A − B"
      case .product: "A · B"
      case .magnitude: "√(A² + B² + C²)"
      case .derivative: "dA/dt"
      case .integral: "∫ A dt"
      case .highPass: "A, high-passed"
      }
    }
  }

  /// The math channel, run incrementally on A's timestamps. B and C are paired with A by
  /// timestamp (interpolated, or held for irregular streams) before they reach here.
  struct MathProcessor: Sendable, Equatable {
    var operation: MathOperation
    var cornerHz: Double
    private var lastTime: Double?
    private var lastValue = 0.0
    private var accumulator = 0.0
    private var highPass: OnePoleHighPass

    init(operation: MathOperation, cornerHz: Double = 1) {
      self.operation = operation
      self.cornerHz = cornerHz
      highPass = OnePoleHighPass(cornerHz: cornerHz)
    }

    mutating func reset() {
      lastTime = nil
      lastValue = 0
      accumulator = 0
      highPass = OnePoleHighPass(cornerHz: cornerHz)
    }

    /// One output sample at `t` (nil when an input is missing; derivative: nil on the first).
    mutating func process(t: Double, a: Float, b: Float? = nil, c: Float? = nil) -> Float? {
      let x = Double(a)
      guard x.isFinite else { return nil }
      var y: Double?
      switch operation {
      case .sum: y = b.map { x + Double($0) }
      case .difference: y = b.map { x - Double($0) }
      case .product: y = b.map { x * Double($0) }
      case .magnitude:
        let bb = Double(b ?? 0)
        let cc = Double(c ?? 0)
        y = (x * x + bb * bb + cc * cc).squareRoot()
      case .derivative:
        if let t0 = lastTime, t > t0 { y = (x - lastValue) / (t - t0) }
      case .integral:
        if let t0 = lastTime, t > t0 { accumulator += 0.5 * (x + lastValue) * (t - t0) }
        y = accumulator
      case .highPass:
        y = highPass.process(x, at: t)
      }
      if lastTime == nil || t > (lastTime ?? t) {
        lastTime = t
        lastValue = x
      }
      guard let y, y.isFinite else { return nil }
      return Float(y)
    }
  }

  // MARK: - Aliasing

  /// A known source above a stream's Nyquist frequency and where it shows up.
  struct AliasNote: Sendable, Equatable, Hashable {
    var source: String
    var frequency: Double
    var sampleRate: Double
    /// Where it appears: |f − f_s·round(f/f_s)| (`RF.DSP.aliasFrequency`).
    var alias: Double
  }

  /// Known sources (label, Hz) that a stream sampled at `sampleRate` cannot show truthfully.
  static func aliasNotes(sources: [(label: String, frequency: Double)], sampleRate: Double?) -> [AliasNote] {
    guard let fs = sampleRate, fs > 0, fs.isFinite else { return [] }
    var seen = Set<String>()
    return sources.compactMap { s in
      guard s.frequency.isFinite, s.frequency > 0, RF.DSP.isAliased(s.frequency, sampleRate: fs),
        seen.insert(s.label).inserted
      else { return nil }
      return AliasNote(
        source: s.label, frequency: s.frequency, sampleRate: fs, alias: RF.DSP.aliasFrequency(s.frequency, sampleRate: fs))
    }
  }

  /// The local mains frequency: 60 Hz in the Americas and a few other regions, 50 Hz elsewhere.
  static func mainsFrequency(region: String?) -> Double {
    let sixty: Set<String> = [
      "US", "CA", "MX", "BR", "CO", "VE", "EC", "PE", "CR", "PA", "GT", "HN", "NI", "SV", "DO", "PR", "CU", "BS",
      "TW", "KR", "PH", "SA", "LR", "BZ", "GU", "AS", "VI",
    ]
    return sixty.contains((region ?? "US").uppercased()) ? 60 : 50
  }

  // MARK: - Streams

  /// What the resolver needs to know about a registered stream.
  struct StreamCandidate: Sendable, Equatable {
    var id: StreamID
    var label: String
    var group: String
    var unit: String
    var rate: Double
    var latest: Float?

    init(id: StreamID, label: String, group: String, unit: String, rate: Double, latest: Float? = nil) {
      self.id = id
      self.label = label
      self.group = group
      self.unit = unit
      self.rate = rate
      self.latest = latest
    }

    init(_ s: SignalStream) {
      self.init(id: s.id, label: s.label, group: s.group, unit: s.unit, rate: s.nominalRate, latest: s.ring.latest?.value)
    }
  }

  /// Finds a stream by meaning (group, axis, keywords) rather than a hard-coded id, so
  /// presets work with the simulated streams now and the live builder's real ones later.
  struct StreamQuery: Codable, Sendable, Hashable {
    enum Rank: Codable, Sendable, Hashable {
      /// Highest keyword score (ties: lowest id).
      case best
      /// The n-th strongest by latest value (BLE RSSI), 0 = strongest.
      case strongest(Int)
      /// The fastest nominal rate.
      case fastest
    }

    var group: String
    /// "x", "y" or "z": matches an id component or a label word.
    var axis: String?
    /// At least one must appear in the id or label (case-insensitive), when non-empty.
    var any: [String] = []
    var prefer: [String] = []
    var avoid: [String] = []
    var rank: Rank = .best

    init(
      group: String, axis: String? = nil, any: [String] = [], prefer: [String] = [], avoid: [String] = [],
      rank: Rank = .best
    ) {
      self.group = group
      self.axis = axis
      self.any = any
      self.prefer = prefer
      self.avoid = avoid
      self.rank = rank
    }
  }

  /// The stream a query names among `candidates`, or nil.
  static func resolve(_ query: StreamQuery, in candidates: [StreamCandidate]) -> StreamID? {
    func text(_ c: StreamCandidate) -> String { (c.id.rawValue + " " + c.label).lowercased() }
    func matchesAxis(_ c: StreamCandidate, _ axis: String) -> Bool {
      let a = axis.lowercased()
      let idParts = c.id.rawValue.lowercased().split(separator: ".").map(String.init)
      let words = c.label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
      return idParts.contains(a) || words.contains(a)
    }
    let pool = candidates.filter { c in
      guard c.group == query.group else { return false }
      if let axis = query.axis, !matchesAxis(c, axis) { return false }
      if !query.any.isEmpty, !query.any.contains(where: { text(c).contains($0.lowercased()) }) { return false }
      return true
    }
    guard !pool.isEmpty else { return nil }
    func score(_ c: StreamCandidate) -> Int {
      let t = text(c)
      return query.prefer.filter { t.contains($0.lowercased()) }.count * 2
        - query.avoid.filter { t.contains($0.lowercased()) }.count * 3
    }
    switch query.rank {
    case .best:
      return pool.min { a, b in
        let sa = score(a)
        let sb = score(b)
        return sa != sb ? sa > sb : a.id < b.id
      }?.id
    case .fastest:
      return pool.min { a, b in a.rate != b.rate ? a.rate > b.rate : a.id < b.id }?.id
    case .strongest(let index):
      let sorted = pool.sorted { a, b in
        let va = a.latest ?? -.infinity
        let vb = b.latest ?? -.infinity
        return va != vb ? va > vb : a.id < b.id
      }
      return index < sorted.count ? sorted[index].id : nil
    }
  }

  /// The sensor that publishes a stream: by its registered group when known, else by the
  /// id prefix (`mag.` → magnetometer, `accel.`/`gyro.`/`attitude.`/`gravity.` → motion, …).
  static func sensor(for id: StreamID, group: String? = nil) -> SensorID? {
    // A registered group decides: Spin's simulated "gyro.tip.i" is not the motion sensor.
    if let group {
      switch group {
      case StreamGroup.magnetometer: return .magnetometer
      case StreamGroup.motion: return .motion
      case StreamGroup.air: return .barometer
      case StreamGroup.audio: return .microphone
      case StreamGroup.bluetooth: return .bluetooth
      case StreamGroup.network: return .network
      case StreamGroup.location: return .location
      case StreamGroup.light: return .light
      case StreamGroup.device: return .charging
      case StreamGroup.spin, StreamGroup.patch: return nil
      default: break  // Radio holds the simulated I/Q and the live UWB / NFC streams: by prefix.
      }
    }
    let raw = id.rawValue.lowercased()
    let prefix = raw.split(separator: ".").first.map(String.init) ?? raw
    switch prefix {
    case "mag", "magnetometer", "compass", "heading": return .magnetometer
    case "accel", "gyro", "attitude", "gravity", "motion", "rotation", "user": return .motion
    case "baro", "pressure", "altitude": return .barometer
    case "mic", "audio", "sound": return .microphone
    case "ble", "bt", "bluetooth": return .bluetooth
    case "net", "wifi", "cell", "network": return .network
    case "gnss", "gps", "location": return .location
    case "light", "camera", "flicker": return .light
    case "battery", "charging", "thermal", "device": return .charging
    case "uwb": return .uwb
    case "nfc": return .nfc
    default: return nil
    }
  }

  // MARK: - CSV

  /// One exported series with its own timestamps.
  struct CSVColumn: Sendable, Equatable {
    var header: String
    var unit: String
    var times: [Double]
    var values: [Float]
  }

  /// The visible window as CSV: a time column and a value column per series (each stream keeps
  /// its own timestamps, in seconds from `origin`), rows padded with empty cells.
  static func csv(_ columns: [CSVColumn], origin: Double) -> String {
    func escape(_ s: String) -> String {
      s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
    var lines: [String] = []
    lines.append(
      columns.map { "\(escape($0.header + " time (s)")),\(escape($0.header + " (" + $0.unit + ")"))" }.joined(separator: ","))
    let rows = columns.map { min($0.times.count, $0.values.count) }.max() ?? 0
    lines.reserveCapacity(rows + 1)
    for r in 0..<rows {
      var cells: [String] = []
      cells.reserveCapacity(columns.count * 2)
      for c in columns {
        if r < c.times.count, r < c.values.count {
          cells.append(String(format: "%.6f", c.times[r] - origin))
          cells.append(c.values[r].isFinite ? String(format: "%.7g", Double(c.values[r])) : "")
        } else {
          cells.append("")
          cells.append("")
        }
      }
      lines.append(cells.joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
