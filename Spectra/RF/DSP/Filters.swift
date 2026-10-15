import Accelerate
import Foundation

// MARK: - FIR design (windowed sinc)

nonisolated extension RF.DSP {
  /// Pass-band shape for FIR and biquad design.
  enum FilterResponse: String, CaseIterable, Codable, Hashable, Sendable {
    case lowpass, highpass, bandpass, bandstop
  }

  /// Windowed-sinc FIR taps. Cut-offs are normalized to the sample rate (0 < f < 0.5).
  /// Low-pass taps sum to 1 (unity DC gain); high-pass uses spectral inversion, so `taps` is
  /// rounded up to an odd count. Band-pass/stop use `cutoff` as the low edge and `upper` as the high.
  static func firTaps(
    _ response: FilterResponse, cutoff: Double, upper: Double? = nil, taps requested: Int,
    window: WindowKind = .blackman
  ) -> [Float] {
    let n = max(1, requested) | 1
    func lowpass(_ fc: Double) -> [Double] {
      let m = Double(n - 1) / 2
      // Symmetric window of length n (denominator n − 1) keeps linear phase exact.
      var h = (0..<n).map { k -> Double in
        let x = Double(k) - m
        let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
        let a = n > 1 ? 2 * Double.pi * Double(k) / Double(n - 1) : 0
        let w: Double
        switch window {
        case .rectangular: w = 1
        case .hann: w = 0.5 - 0.5 * cos(a)
        case .hamming: w = 0.54 - 0.46 * cos(a)
        case .blackman: w = 0.42 - 0.5 * cos(a) + 0.08 * cos(2 * a)
        }
        return sinc * w
      }
      let sum = h.reduce(0, +)
      if sum != 0 { h = h.map { $0 / sum } }
      return h
    }
    let mid = (n - 1) / 2
    var h: [Double]
    switch response {
    case .lowpass:
      h = lowpass(cutoff)
    case .highpass:
      h = lowpass(cutoff).map { -$0 }
      h[mid] += 1
    case .bandpass:
      let hi = lowpass(upper ?? min(0.49, cutoff * 2))
      let lo = lowpass(cutoff)
      h = zip(hi, lo).map { $0 - $1 }
    case .bandstop:
      let hi = lowpass(upper ?? min(0.49, cutoff * 2))
      let lo = lowpass(cutoff)
      h = zip(lo, hi).map { $0 - $1 }
      h[mid] += 1
    }
    return h.map { Float($0) }
  }

  /// Magnitude response |H(f)| of FIR taps at normalized frequency f (cycles/sample).
  static func firMagnitude(_ taps: [Float], at f: Double) -> Double {
    var re = 0.0
    var im = 0.0
    for (k, h) in taps.enumerated() {
      let a = -2 * Double.pi * f * Double(k)
      re += Double(h) * cos(a)
      im += Double(h) * sin(a)
    }
    return (re * re + im * im).squareRoot()
  }
}

// MARK: - Streaming FIR

nonisolated extension RF.DSP {
  /// A streaming FIR filter: keeps the last `taps − 1` inputs so consecutive blocks join without
  /// seams. Uses vDSP_conv on [history | block]. Group delay = (taps − 1)/2 samples.
  struct FIRFilter: Sendable {
    let taps: [Float]
    private let reversed: [Float]
    private var history: [Float]
    private var extended: [Float] = []

    init(taps: [Float]) {
      precondition(!taps.isEmpty, "FIRFilter needs at least one tap")
      self.taps = taps
      reversed = taps.reversed()
      history = [Float](repeating: 0, count: taps.count - 1)
    }

    /// Group delay in samples.
    var delay: Double { Double(taps.count - 1) / 2 }

    /// Clears the history.
    mutating func reset() {
      for k in history.indices { history[k] = 0 }
    }

    /// Filters one block, writing `x.count` outputs into `y`.
    mutating func process(_ x: [Float], into y: inout [Float]) {
      let p = taps.count
      let n = x.count
      if y.count != n { y = [Float](repeating: 0, count: n) }
      guard n > 0 else { return }
      let total = n + p - 1
      if extended.count != total { extended = [Float](repeating: 0, count: total) }
      for k in 0..<(p - 1) { extended[k] = history[k] }
      for k in 0..<n { extended[p - 1 + k] = x[k] }
      vDSP_conv(extended, 1, reversed, 1, &y, 1, vDSP_Length(n), vDSP_Length(p))
      for k in 0..<(p - 1) { history[k] = extended[n + k] }
    }

    /// Filters one block (allocating variant).
    mutating func process(_ x: [Float]) -> [Float] {
      var y = [Float]()
      process(x, into: &y)
      return y
    }
  }

  /// A FIR applied to complex samples (one history per rail).
  struct ComplexFIRFilter: Sendable {
    private var fi: FIRFilter
    private var fq: FIRFilter

    init(taps: [Float]) {
      fi = FIRFilter(taps: taps)
      fq = FIRFilter(taps: taps)
    }

    var delay: Double { fi.delay }
    var taps: [Float] { fi.taps }

    mutating func reset() {
      fi.reset()
      fq.reset()
    }

    mutating func process(_ x: RF.IQBuffer, into y: inout RF.IQBuffer) {
      fi.process(x.i, into: &y.i)
      fq.process(x.q, into: &y.q)
    }

    mutating func process(_ x: RF.IQBuffer) -> RF.IQBuffer {
      var y = RF.IQBuffer()
      process(x, into: &y)
      return y
    }
  }
}

// MARK: - Biquad (RBJ audio-EQ cookbook)

nonisolated extension RF.DSP {
  /// A second-order IIR section in transposed direct form II (double-precision state).
  /// Coefficients follow R. Bristow-Johnson's cookbook, normalized so a0 = 1.
  struct Biquad: Hashable, Sendable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
      self.b0 = b0
      self.b1 = b1
      self.b2 = b2
      self.a1 = a1
      self.a2 = a2
    }

    /// Designs a section. `frequency` is the corner/centre in Hz; Q defaults to 1/√2 (Butterworth).
    init(_ response: FilterResponse, frequency: Double, sampleRate: Double, q: Double = 1 / 2.0.squareRoot()) {
      let w0 = 2 * Double.pi * frequency / sampleRate
      let cw = cos(w0)
      let alpha = sin(w0) / (2 * q)
      let a0 = 1 + alpha
      var b = (0.0, 0.0, 0.0)
      switch response {
      case .lowpass: b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
      case .highpass: b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
      case .bandpass: b = (alpha, 0, -alpha)
      case .bandstop: b = (1, -2 * cw, 1)
      }
      self.init(b0: b.0 / a0, b1: b.1 / a0, b2: b.2 / a0, a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    mutating func reset() {
      z1 = 0
      z2 = 0
    }

    /// Filters one sample.
    @inline(__always) mutating func process(_ x: Double) -> Double {
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      return y
    }

    /// Filters a block in place.
    mutating func process(_ x: inout [Float]) {
      for k in x.indices { x[k] = Float(process(Double(x[k]))) }
    }

    /// |H(f)| at frequency f (Hz).
    func magnitude(at f: Double, sampleRate: Double) -> Double {
      let w = 2 * Double.pi * f / sampleRate
      let z1 = RF.Complex.expj(-w)
      let z2 = RF.Complex.expj(-2 * w)
      let num = RF.Complex(b0) + z1 * b1 + z2 * b2
      let den = RF.Complex(1) + z1 * a1 + z2 * a2
      return (num / den).magnitude
    }
  }

  /// One-pole DC blocker y[n] = x[n] − x[n−1] + R·y[n−1] (R close to 1).
  struct DCBlocker: Hashable, Sendable {
    var r: Double
    private var x1 = 0.0
    private var y1 = 0.0

    /// `cornerHz` sets R = 1 − 2π·f_c/f_s.
    init(cornerHz: Double, sampleRate: Double) {
      r = max(0, 1 - 2 * Double.pi * cornerHz / sampleRate)
    }

    mutating func reset() {
      x1 = 0
      y1 = 0
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
      let y = x - x1 + r * y1
      x1 = x
      y1 = y
      return y
    }
  }
}

// MARK: - Rate conversion

nonisolated extension RF.DSP {
  /// Low-pass filters (cut-off 0.45/factor of the input rate) and keeps every `factor`-th sample.
  /// Uses vDSP_desamp. The output has ⌊(x.count − taps)/factor⌋ + 1 samples (filter edge trimmed).
  static func decimate(_ x: [Float], factor: Int, taps: Int = 63) -> [Float] {
    guard factor > 1 else { return x }
    let h = firTaps(.lowpass, cutoff: 0.45 / Double(factor), taps: taps)
    guard x.count >= h.count else { return [] }
    let outCount = (x.count - h.count) / factor + 1
    var y = [Float](repeating: 0, count: outCount)
    let reversed = Array(h.reversed())
    vDSP_desamp(x, vDSP_Stride(factor), reversed, &y, vDSP_Length(outCount), vDSP_Length(h.count))
    return y
  }

  /// Linear-interpolation resampler from `inputRate` to `outputRate` (good for display and for
  /// band-limited audio; use `decimate` first for large down-sampling ratios).
  /// Output length is capped at 2²² samples; non-finite or non-positive rates return the input.
  static func resampleLinear(_ x: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
    guard x.count > 1, inputRate > 0, outputRate > 0, inputRate.isFinite, outputRate.isFinite else { return x }
    let ratio = inputRate / outputRate
    let outCount = Int(min((Double(x.count - 1) / ratio).rounded(.down), 4_194_303)) + 1
    var y = [Float](repeating: 0, count: outCount)
    for n in 0..<outCount {
      let t = Double(n) * ratio
      let k = min(Int(t), x.count - 2)
      let f = Float(t - Double(k))
      y[n] = x[k] + (x[k + 1] - x[k]) * f
    }
    return y
  }

  /// Inserts `factor − 1` zeros after every sample (the first step of interpolation).
  static func zeroStuff(_ x: RF.IQBuffer, factor: Int) -> RF.IQBuffer {
    var y = RF.IQBuffer(count: x.count * factor)
    for n in 0..<x.count {
      y.i[n * factor] = x.i[n]
      y.q[n * factor] = x.q[n]
    }
    return y
  }
}
