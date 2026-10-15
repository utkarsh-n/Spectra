import Foundation

/// One stream as the scope holds it: a copy of its newest samples, raw and as displayed
/// (after coupling and invert), filled incrementally from the stream's ring so the coupling
/// filters run continuously instead of restarting every frame. Keeps up to
/// `ScopeEngine.history` seconds, longer than short rings such as the microphone's 2 s.
@MainActor
final class ScopeTrack {
  let stream: SignalStream
  private(set) var times: [Double] = []
  private(set) var raw: [Float] = []
  /// Displayed values: coupled, then inverted.
  private(set) var values: [Float] = []
  private(set) var coupling: ScopeCoupling
  private(set) var invert: Bool
  /// The gravity stream subtracted by "No gravity" on a raw accelerometer axis.
  private(set) var gravity: SignalStream?
  private var gravityTimes: [Double] = []
  private var gravityValues: [Float] = []
  private var filter: ScopeEngine.OnePoleHighPass?
  private var lastTime = -Double.infinity
  private var lastGravityTime = -Double.infinity
  /// Samples kept.
  let capacity: Int
  /// When the model last looked for this axis's gravity stream (`SignalClock` seconds).
  var gravityChecked = -Double.infinity

  init(stream: SignalStream, coupling: ScopeCoupling, invert: Bool, gravity: SignalStream?) {
    self.stream = stream
    self.coupling = coupling
    self.invert = invert
    self.gravity = gravity
    let rate = stream.nominalRate
    if rate > 0 {
      let seconds = ScopeEngine.history(ringCapacity: stream.ring.capacity, rate: rate)
      capacity = max(stream.ring.capacity, min(400_000, Int((seconds * rate).rounded(.up))))
    } else {
      capacity = max(stream.ring.capacity, 8192)
    }
    filter = Self.makeFilter(coupling, stream: stream, hasGravity: gravity != nil)
  }

  var id: StreamID { stream.id }
  var isIrregular: Bool { stream.isIrregular }
  var latestTime: Double? { times.last }
  var count: Int { times.count }

  /// Measured rate, or the nominal rate. Regular streams use the median interval of their
  /// newest 4096 timestamps (this track's own copy, so the ring's lock is not taken): a gap
  /// (a stalled producer that skips ahead, a camera's blanking between frames) does not drag
  /// the rate down the way samples ÷ seconds does, and the FFT and the timebase then use the
  /// spacing the samples really have. Irregular streams use the stream's events per second.
  /// Refreshed at most twice a second; the per-frame callers read the cached value.
  var rate: Double? {
    let now = SignalClock.now()
    if now - rateCheckedAt > 0.5 {
      rateCheckedAt = now
      let measured = stream.isIrregular ? stream.measuredRate : Self.medianRate(times)
      if let measured, measured > 0, measured.isFinite {
        cachedRate = measured
      } else {
        cachedRate = stream.nominalRate > 0 ? stream.nominalRate : nil
      }
    }
    return cachedRate
  }

  /// 1 / median interval of the newest `last` timestamps (nil with fewer than 8 intervals).
  nonisolated static func medianRate(_ times: [Double], last: Int = 4096) -> Double? {
    let n = times.count
    guard n > 8 else { return nil }
    var intervals: [Double] = []
    intervals.reserveCapacity(min(n - 1, last))
    for i in max(1, n - last)..<n {
      let dt = times[i] - times[i - 1]
      if dt > 0, dt.isFinite { intervals.append(dt) }
    }
    guard intervals.count >= 8 else { return nil }
    intervals.sort()
    let k = intervals.count / 2
    let median = intervals.count % 2 == 1 ? intervals[k] : 0.5 * (intervals[k - 1] + intervals[k])
    return median > 0 ? 1 / median : nil
  }
  private var cachedRate: Double?
  private var rateCheckedAt = -Double.infinity

  /// Whether "No gravity" uses a gravity stream (true) or a 0.25 Hz high-pass (false).
  var subtractsGravityStream: Bool { coupling == .removeGravity && gravity != nil }

  /// Reads everything new in the ring.
  func ingest() {
    if let gravity, coupling == .removeGravity {
      let g = gravity.ring.snapshot(since: lastGravityTime)
      if !g.isEmpty {
        gravityTimes.append(contentsOf: g.times)
        gravityValues.append(contentsOf: g.values)
        lastGravityTime = g.times.last ?? lastGravityTime
        if gravityTimes.count > 4096 {
          gravityTimes.removeFirst(gravityTimes.count - 2048)
          gravityValues.removeFirst(gravityValues.count - 2048)
        }
      }
    }
    let snap = stream.ring.snapshot(since: lastTime)
    guard !snap.isEmpty else { return }
    times.reserveCapacity(times.count + snap.count)
    for k in 0..<snap.count {
      let t = snap.times[k]
      let v = snap.values[k]
      times.append(t)
      raw.append(v)
      values.append(process(v, at: t))
    }
    lastTime = snap.times.last ?? lastTime
    trim()
  }

  /// Changes coupling or invert and reprocesses the cached samples (filters restart from the
  /// oldest cached sample, so the visible window has settled).
  func configure(coupling: ScopeCoupling, invert: Bool, gravity: SignalStream?) {
    guard coupling != self.coupling || invert != self.invert || gravity !== self.gravity else { return }
    if gravity !== self.gravity {
      gravityTimes = []
      gravityValues = []
      lastGravityTime = -.infinity
      self.gravity = gravity
      if coupling == .removeGravity, let gravity {
        let g = gravity.ring.snapshot()
        gravityTimes = g.times
        gravityValues = g.values
        lastGravityTime = g.times.last ?? lastGravityTime
      }
    } else if coupling == .removeGravity, self.coupling != .removeGravity, let gravity {
      let g = gravity.ring.snapshot()
      gravityTimes = g.times
      gravityValues = g.values
      lastGravityTime = g.times.last ?? lastGravityTime
    }
    self.coupling = coupling
    self.invert = invert
    filter = Self.makeFilter(coupling, stream: stream, hasGravity: gravity != nil)
    values = zip(raw, times).map { process($0, at: $1) }
  }

  /// Displayed samples with times inside `window` (plus one either side when `margin`).
  func window(_ window: ClosedRange<Double>, margin: Bool = false) -> (values: [Float], times: [Double]) {
    var lo = ScopeEngine.lowerBound(times, window.lowerBound)
    var hi = ScopeEngine.upperBound(times, window.upperBound)
    if margin {
      lo = max(0, lo - 1)
      hi = min(times.count, hi + 1)
    }
    guard lo < hi else { return ([], []) }
    return (Array(values[lo..<hi]), Array(times[lo..<hi]))
  }

  /// The samples auto-scale fits to: the window with one sample either side, or, for a slow
  /// stream beside a fast one (fewer than three there: 10 Hz illuminance under a 50 ms sweep),
  /// its newest eight samples, so its held trace is scaled to what it has been reading.
  func fitSamples(_ window: ClosedRange<Double>) -> (values: [Float], times: [Double]) {
    let w = self.window(window, margin: true)
    return w.values.count >= 3 ? w : suffix(8)
  }

  /// The newest `count` displayed samples.
  func suffix(_ count: Int) -> (values: [Float], times: [Double]) {
    (Array(values.suffix(count)), Array(times.suffix(count)))
  }

  private func process(_ v: Float, at t: Double) -> Float {
    var y = Double(v)
    switch coupling {
    case .dc:
      break
    case .removeGravity where gravity != nil:
      if let g = ScopeEngine.value(at: t, values: gravityValues, times: gravityTimes, hold: false, tolerance: 0.05) {
        y -= Double(g)
      } else if let last = gravityValues.last {
        y -= Double(last)
      }
    case .ac, .removeGravity, .removeEarthField:
      if var f = filter {
        y = f.process(y, at: t)
        filter = f
      }
    }
    if invert { y = -y }
    return Float(y)
  }

  private func trim() {
    guard times.count > capacity + capacity / 4 else { return }
    let drop = times.count - capacity
    times.removeFirst(drop)
    raw.removeFirst(drop)
    values.removeFirst(drop)
  }

  /// Corner frequencies: AC f_s/50 (0.05…10 Hz); No gravity 0.25 Hz when no gravity stream
  /// exists; No Earth field 0.01 Hz (a 16 s baseline, so a magnet approaching over seconds and
  /// mains hum stay visible while the steady ~50 µT goes).
  private static func makeFilter(_ coupling: ScopeCoupling, stream: SignalStream, hasGravity: Bool)
    -> ScopeEngine.OnePoleHighPass?
  {
    switch coupling {
    case .dc: nil
    case .ac:
      ScopeEngine.OnePoleHighPass(cornerHz: ScopeEngine.acCorner(sampleRate: stream.nominalRate > 0 ? stream.nominalRate : nil))
    case .removeGravity: hasGravity ? nil : ScopeEngine.OnePoleHighPass(cornerHz: ScopeEngine.gravityCorner)
    case .removeEarthField: ScopeEngine.OnePoleHighPass(cornerHz: ScopeEngine.earthFieldCorner)
    }
  }
}

/// The math channel's samples, computed incrementally on input A's timestamps.
@MainActor
final class ScopeMathTrack {
  let operation: ScopeEngine.MathOperation
  let cornerHz: Double
  private(set) var times: [Double] = []
  private(set) var values: [Float] = []
  private var processor: ScopeEngine.MathProcessor
  private var lastTime = -Double.infinity
  let capacity: Int

  init(operation: ScopeEngine.MathOperation, cornerHz: Double, capacity: Int) {
    self.operation = operation
    self.cornerHz = cornerHz
    self.capacity = max(1024, capacity)
    processor = ScopeEngine.MathProcessor(operation: operation, cornerHz: cornerHz)
  }

  var latestTime: Double? { times.last }

  /// Processes A's samples newer than the last output, up to the newest instant B and C cover.
  func update(
    a: (values: [Float], times: [Double]), b: (values: [Float], times: [Double])?,
    c: (values: [Float], times: [Double])?, holdB: Bool, holdC: Bool
  ) {
    let start = ScopeEngine.upperBound(a.times, lastTime)
    guard start < a.times.count else { return }
    var limit = a.times[a.times.count - 1]
    if operation.inputs >= 2, let b {
      guard let last = b.times.last else { return }
      if !holdB { limit = min(limit, last) }
    }
    if operation.inputs >= 3, let c {
      guard let last = c.times.last else { return }
      if !holdC { limit = min(limit, last) }
    }
    for i in start..<a.times.count {
      let t = a.times[i]
      guard t <= limit else { break }
      let bv = operation.inputs >= 2 ? b.flatMap { ScopeEngine.value(at: t, values: $0.values, times: $0.times, hold: holdB, tolerance: 0.25) } : nil
      let cv = operation.inputs >= 3 ? c.flatMap { ScopeEngine.value(at: t, values: $0.values, times: $0.times, hold: holdC, tolerance: 0.25) } : nil
      if operation.inputs >= 2, bv == nil, operation != .magnitude {
        lastTime = t
        continue
      }
      if let y = processor.process(t: t, a: a.values[i], b: bv, c: cv) {
        times.append(t)
        values.append(y)
      }
      lastTime = t
    }
    if times.count > capacity + capacity / 4 {
      let drop = times.count - capacity
      times.removeFirst(drop)
      values.removeFirst(drop)
    }
  }

  func window(_ window: ClosedRange<Double>, margin: Bool = false) -> (values: [Float], times: [Double]) {
    var lo = ScopeEngine.lowerBound(times, window.lowerBound)
    var hi = ScopeEngine.upperBound(times, window.upperBound)
    if margin {
      lo = max(0, lo - 1)
      hi = min(times.count, hi + 1)
    }
    guard lo < hi else { return ([], []) }
    return (Array(values[lo..<hi]), Array(times[lo..<hi]))
  }
}
