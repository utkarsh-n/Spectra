import Accelerate
import Foundation
import simd

/// Frequency measurement on simulated records: the nod of the heavy top, the precession of a
/// rotor, the line of an FID. A Hann-windowed record is located coarsely with a 4× zero-padded
/// FFT, then its DTFT is maximized at any frequency (not just bins) by golden-section search,
/// so a few seconds of signal give the tone to better than 1e-4. Pure; used by readouts and by
/// the tests.
nonisolated enum SpinAnalysis {
  /// Hann window of `count` points (periodic form, sums to count/2).
  static func hann(count: Int) -> [Double] {
    guard count > 1 else { return [1] }
    return (0..<count).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count)) }
  }

  /// |X(f)|² of the windowed real record `x` (mean removed) at frequency `f` hertz.
  static func power(_ x: [Double], sampleRate: Double, at f: Double, window: [Double]? = nil) -> Double {
    dtftPower(windowed(x, window: window), sampleRate: sampleRate, at: f)
  }

  /// |X(f)|² of the windowed complex record `iq` (I = x, Q = y) at signed frequency `f`
  /// (forward transform e^(−i2πft)): positive frequencies turn counterclockwise.
  static func power(iq: [SIMD2<Double>], sampleRate: Double, at f: Double, window: [Double]? = nil) -> Double {
    dtftPower(windowed(iq: iq, window: window), sampleRate: sampleRate, at: f)
  }

  /// The strongest tone of a real record inside `band` (Hz).
  static func toneFrequency(_ x: [Double], sampleRate: Double, in band: ClosedRange<Double>) -> Double {
    peak(windowed(x, window: nil), sampleRate: sampleRate, in: band).frequency
  }

  /// The strongest tone of a complex record inside `band` (signed Hz).
  static func toneFrequency(iq: [SIMD2<Double>], sampleRate: Double, in band: ClosedRange<Double>) -> Double {
    peak(windowed(iq: iq, window: nil), sampleRate: sampleRate, in: band).frequency
  }

  /// The largest windowed power |X(f)|² inside `band` for a complex record (for dBc comparisons).
  static func peakPower(iq: [SIMD2<Double>], sampleRate: Double, in band: ClosedRange<Double>) -> Double {
    peak(windowed(iq: iq, window: nil), sampleRate: sampleRate, in: band).power
  }

  // MARK: Internals

  /// The caller's window if it fits the record, else Hann (a short window would index past
  /// its end).
  private static func window(_ window: [Double]?, count: Int) -> [Double] {
    if let w = window, w.count == count { return w }
    return hann(count: count)
  }

  /// (x − mean)·w as a complex record.
  private static func windowed(_ x: [Double], window: [Double]?) -> [SIMD2<Double>] {
    let w = Self.window(window, count: x.count)
    let mean = x.reduce(0, +) / Double(max(x.count, 1))
    return x.indices.map { SIMD2((x[$0] - mean) * w[$0], 0) }
  }

  private static func windowed(iq: [SIMD2<Double>], window: [Double]?) -> [SIMD2<Double>] {
    let w = Self.window(window, count: iq.count)
    return iq.indices.map { iq[$0] * w[$0] }
  }

  /// |Σ s(n)·e^(−i2πfn/fs)|², the twiddle advanced by an exact complex rotation.
  private static func dtftPower(_ s: [SIMD2<Double>], sampleRate: Double, at f: Double) -> Double {
    guard !s.isEmpty, sampleRate > 0 else { return 0 }
    let step = -2 * Double.pi * f / sampleRate
    let rot = SIMD2(cos(step), sin(step))
    var tw = SIMD2<Double>(1, 0)
    var acc = SIMD2<Double>(0, 0)
    for n in s.indices {
      if n & 1023 == 0 {  // re-anchor the twiddle so rounding never accumulates
        let a = step * Double(n)
        tw = SIMD2(cos(a), sin(a))
      }
      let v = s[n]
      acc += SIMD2(v.x * tw.x - v.y * tw.y, v.x * tw.y + v.y * tw.x)
      tw = SIMD2(tw.x * rot.x - tw.y * rot.y, tw.x * rot.y + tw.y * rot.x)
    }
    return simd_length_squared(acc)
  }

  /// Coarse maximum on a 4× zero-padded FFT grid inside `band`, then golden-section
  /// refinement of the DTFT within ± one grid step. The band is first clipped to ±fs/2 (the
  /// DTFT repeats every fs, and a real record mirrors at fs − f), so an open-ended band like
  /// `0...(.infinity)` is safe and finds the tone, not its image.
  private static func peak(_ s: [SIMD2<Double>], sampleRate: Double, in requested: ClosedRange<Double>) -> (frequency: Double, power: Double) {
    guard !s.isEmpty, sampleRate > 0, sampleRate.isFinite else { return (requested.lowerBound, 0) }
    let lo = max(requested.lowerBound, -0.5 * sampleRate)
    let hi = min(requested.upperBound, 0.5 * sampleRate)
    guard lo <= hi else { return (requested.lowerBound, 0) }
    let band = lo...hi
    var n = 16
    while n < 4 * s.count { n *= 2 }
    let grid = sampleRate / Double(n)
    var best = SpinMath.clamp(0.5 * (band.lowerBound + band.upperBound), band.lowerBound, band.upperBound)
    if let spectrum = fftPower(s, size: n) {
      var bestP = -1.0
      let kLow = Int((band.lowerBound / grid).rounded(.up))
      let kHigh = Int((band.upperBound / grid).rounded(.down))
      if kLow <= kHigh {
        for k in kLow...kHigh {
          let p = spectrum[((k % n) + n) % n]
          if p > bestP {
            bestP = p
            best = Double(k) * grid
          }
        }
      }
    }
    var a = max(band.lowerBound, best - grid)
    var b = min(band.upperBound, best + grid)
    guard b > a else { return (best, dtftPower(s, sampleRate: sampleRate, at: best)) }
    let g = (5.0.squareRoot() - 1) / 2
    var c = b - g * (b - a)
    var e = a + g * (b - a)
    var pc = dtftPower(s, sampleRate: sampleRate, at: c)
    var pe = dtftPower(s, sampleRate: sampleRate, at: e)
    for _ in 0..<48 {
      if pc > pe {
        b = e
        e = c
        pe = pc
        c = b - g * (b - a)
        pc = dtftPower(s, sampleRate: sampleRate, at: c)
      } else {
        a = c
        c = e
        pc = pe
        e = a + g * (b - a)
        pe = dtftPower(s, sampleRate: sampleRate, at: e)
      }
    }
    let f = 0.5 * (a + b)
    return (f, dtftPower(s, sampleRate: sampleRate, at: f))
  }

  /// |FFT|² of `s` zero-filled to `size` (a power of two), bin k at k·fs/size (wrapping).
  private static func fftPower(_ s: [SIMD2<Double>], size: Int) -> [Double]? {
    guard
      let dft = try? vDSP.DiscreteFourierTransform(
        count: size, direction: .forward, transformType: .complexComplex, ofType: Double.self)
    else { return nil }
    var re = [Double](repeating: 0, count: size)
    var im = [Double](repeating: 0, count: size)
    for i in s.indices {
      re[i] = s[i].x
      im[i] = s[i].y
    }
    var outRe = [Double](repeating: 0, count: size)
    var outIm = [Double](repeating: 0, count: size)
    dft.transform(inputReal: re, inputImaginary: im, outputReal: &outRe, outputImaginary: &outIm)
    return (0..<size).map { outRe[$0] * outRe[$0] + outIm[$0] * outIm[$0] }
  }
}
