import Accelerate
import Foundation

// MARK: - Bin math and aliasing (rf-physics G.1, G.3)

nonisolated extension RF.DSP {
  /// Frequency of bin k: f_k = k·f_s/N.
  static func binFrequency(_ k: Int, sampleRate fs: Double, count n: Int) -> Double { Double(k) * fs / Double(n) }

  /// Bin spacing Δf = f_s/N (48 kHz, N 4096 → 11.718 75 Hz).
  static func resolution(sampleRate fs: Double, count n: Int) -> Double { fs / Double(n) }

  /// Duration of an N-sample window, N/f_s (48 kHz, 4096 → 85.333 ms).
  static func windowDuration(sampleRate fs: Double, count n: Int) -> Double { Double(n) / fs }

  /// Apparent frequency of a tone f sampled at f_s: |f − f_s·round(f/f_s)| (60 Hz at 100 Hz → 40 Hz).
  static func aliasFrequency(_ f: Double, sampleRate fs: Double) -> Double {
    abs(f - fs * (f / fs).rounded(.toNearestOrAwayFromZero))
  }

  /// True when f lies above the Nyquist frequency f_s/2 and therefore folds.
  static func isAliased(_ f: Double, sampleRate fs: Double) -> Bool { f > fs / 2 }

  /// Smallest power of two ≥ n.
  static func nextPowerOfTwo(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return p
  }

  /// Bin centre frequencies of an fftshifted N-point complex spectrum: −f_s/2 … f_s/2 − Δf.
  static func shiftedFrequencies(count n: Int, sampleRate fs: Double) -> [Double] {
    (0..<n).map { Double($0 - n / 2) * fs / Double(n) }
  }

  /// Bin centre frequencies of a one-sided real spectrum: 0 … f_s/2 (N/2 + 1 bins).
  static func oneSidedFrequencies(count n: Int, sampleRate fs: Double) -> [Double] {
    (0...(n / 2)).map { Double($0) * fs / Double(n) }
  }
}

// MARK: - Spectrum analyzer

nonisolated extension RF {
  /// Windowed-FFT power spectra with preallocated work buffers (Hann by default). One analyzer per
  /// view; calling it does not allocate when you pass an output array of the right size.
  struct SpectrumAnalyzer: Sendable {
    /// How power is referenced.
    enum Scaling: Hashable, Sendable {
      /// A tone of amplitude A centred on a bin reads 20·log10 A (dBFS for full scale 1).
      case tone
      /// Power spectral density in dB/Hz: |X|²/(f_s·Σw²); white noise of variance σ² reads σ²/f_s.
      case density(sampleRate: Double)
    }

    /// FFT length.
    let count: Int
    let windowKind: RF.DSP.WindowKind
    let window: [Float]
    /// Σw/N.
    let coherentGain: Double
    /// Equivalent noise bandwidth in bins.
    let noiseBandwidthBins: Double

    private let fft: RF.FFT
    private let windowEnergy: Double
    private var work: IQBuffer
    private var power: [Float]

    /// Returns nil unless `count` is a power of two ≥ 8.
    init?(count: Int, window kind: RF.DSP.WindowKind = .hann) {
      guard let fft = RF.FFT(count: count) else { return nil }
      self.fft = fft
      self.count = count
      windowKind = kind
      window = RF.DSP.window(kind, count: count)
      coherentGain = RF.DSP.coherentGain(window)
      noiseBandwidthBins = RF.DSP.equivalentNoiseBandwidth(window)
      windowEnergy = window.reduce(0.0) { $0 + Double($1) * Double($1) }
      work = IQBuffer(count: count)
      power = [Float](repeating: 0, count: count)
    }

    /// Loads `x` (first `count` samples, zero-padded) times the window into the work buffer and
    /// transforms it.
    private mutating func transform(i: [Float], q: [Float]?) {
      let n = min(count, i.count)
      for k in 0..<n {
        work.i[k] = i[k] * window[k]
        work.q[k] = (q?[k] ?? 0) * window[k]
      }
      for k in n..<count {
        work.i[k] = 0
        work.q[k] = 0
      }
      fft.forward(&work)
      work.withSplitComplex { s in vDSP_zvmags(&s, 1, &power, 1, vDSP_Length(count)) }
    }

    private func reference(_ scaling: Scaling) -> Double {
      switch scaling {
      case .tone:
        let g = Double(count) * coherentGain
        return g * g
      case .density(let fs):
        return fs * windowEnergy
      }
    }

    /// Two-sided power spectrum in dB of complex samples, fftshifted so index 0 is −f_s/2 and
    /// index N/2 is DC. Writes into `out` (resized to `count` if needed).
    mutating func powerDB(_ x: IQBuffer, scaling: Scaling = .tone, floorDB: Float = -200, into out: inout [Float]) {
      transform(i: x.i, q: x.q)
      if out.count != count { out = [Float](repeating: 0, count: count) }
      let ref = Float(reference(scaling))
      let floorPower = ref * powf(10, floorDB / 10)
      let half = count / 2
      for k in 0..<count {
        let p = max(power[k], floorPower) / ref
        out[(k + half) % count] = 10 * log10f(p)
      }
    }

    /// Two-sided, fftshifted power spectrum in dB (allocating variant).
    mutating func powerDB(_ x: IQBuffer, scaling: Scaling = .tone, floorDB: Float = -200) -> [Float] {
      var out = [Float]()
      powerDB(x, scaling: scaling, floorDB: floorDB, into: &out)
      return out
    }

    /// One-sided spectrum of a real signal, N/2 + 1 bins (0 … f_s/2). With `.tone` a cosine of
    /// amplitude A at a bin centre reads 20·log10 A; with `.density` the one-sided PSD in dB/Hz.
    mutating func realSpectrumDB(_ x: [Float], scaling: Scaling = .tone, floorDB: Float = -200, into out: inout [Float]) {
      transform(i: x, q: nil)
      let bins = count / 2 + 1
      if out.count != bins { out = [Float](repeating: 0, count: bins) }
      let ref = Float(reference(scaling))
      let floorPower = ref * powf(10, floorDB / 10)
      // Folding the negative frequencies: amplitude ×2 (power ×4) for a tone, power ×2 for a density.
      let interiorFactor: Float = scaling == .tone ? 4 : 2
      for k in 0..<bins {
        let factor: Float = (k == 0 || k == count / 2) ? 1 : interiorFactor
        out[k] = 10 * log10f(max(power[k] * factor, floorPower) / ref)
      }
    }

    /// One-sided real spectrum in dB (allocating variant).
    mutating func realSpectrumDB(_ x: [Float], scaling: Scaling = .tone, floorDB: Float = -200) -> [Float] {
      var out = [Float]()
      realSpectrumDB(x, scaling: scaling, floorDB: floorDB, into: &out)
      return out
    }

    /// Welch-averaged two-sided spectrum in dB (fftshifted): the mean power of Hann segments of
    /// `count` samples with 50 % overlap across the whole buffer — a steadier picture of noise-like
    /// signals (OFDM, spread spectrum) than a single FFT. Falls back to one zero-padded segment
    /// when `x` is shorter than `count`.
    mutating func averagedPowerDB(_ x: IQBuffer, scaling: Scaling = .tone, floorDB: Float = -200, into out: inout [Float]) {
      if out.count != count { out = [Float](repeating: 0, count: count) }
      let hop = max(1, count / 2)
      var sum = [Double](repeating: 0, count: count)
      var segments = 0
      var start = 0
      repeat {
        let end = min(x.count, start + count)
        if end > start {
          transform(i: Array(x.i[start..<end]), q: Array(x.q[start..<end]))
          for k in 0..<count { sum[k] += Double(power[k]) }
          segments += 1
        }
        start += hop
      } while start + count <= x.count
      let ref = reference(scaling) * Double(max(segments, 1))
      let floorPower = pow(10, Double(floorDB) / 10)
      let half = count / 2
      for k in 0..<count {
        out[(k + half) % count] = Float(10 * log10(max(sum[k] / ref, floorPower)))
      }
    }

    /// Welch-averaged spectrum (allocating variant).
    mutating func averagedPowerDB(_ x: IQBuffer, scaling: Scaling = .tone, floorDB: Float = -200) -> [Float] {
      var out = [Float]()
      averagedPowerDB(x, scaling: scaling, floorDB: floorDB, into: &out)
      return out
    }

    /// Index and frequency of the strongest bin of a one-sided real spectrum, refined by parabolic
    /// interpolation of the dB values (good to a small fraction of a bin for Hann).
    static func peak(ofOneSided db: [Float], sampleRate fs: Double, count n: Int, ignoringDC: Bool = true) -> (bin: Int, frequency: Double, levelDB: Float)? {
      guard db.count > 2 else { return nil }
      let start = ignoringDC ? 1 : 0
      var best = start
      for k in start..<db.count where db[k] > db[best] { best = k }
      var delta = 0.0
      if best > 0, best < db.count - 1 {
        let a = Double(db[best - 1])
        let b = Double(db[best])
        let c = Double(db[best + 1])
        let den = a - 2 * b + c
        if den != 0 { delta = 0.5 * (a - c) / den }
      }
      return (best, (Double(best) + delta) * fs / Double(n), db[best])
    }
  }
}
