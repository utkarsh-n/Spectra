import Foundation

nonisolated extension RF.DSP {
  /// Analysis windows. All are the *periodic* forms (denominator N, like vDSP), which is what
  /// spectral analysis wants (rf-physics G.2).
  enum WindowKind: String, CaseIterable, Codable, Hashable, Sendable {
    case rectangular, hann, hamming, blackman

    var displayName: String {
      switch self {
      case .rectangular: "Rectangular"
      case .hann: "Hann"
      case .hamming: "Hamming"
      case .blackman: "Blackman"
      }
    }
  }

  /// Window coefficients of length `count`:
  /// Hann `0.5(1 − cos 2πn/N)`, Hamming `0.54 − 0.46 cos 2πn/N`,
  /// Blackman `0.42 − 0.5 cos 2πn/N + 0.08 cos 4πn/N` (vDSP_blkman_window).
  static func window(_ kind: WindowKind, count: Int) -> [Float] {
    guard count > 0 else { return [] }
    let n = Double(count)
    return (0..<count).map { k in
      let a = 2 * Double.pi * Double(k) / n
      switch kind {
      case .rectangular: return 1
      case .hann: return Float(0.5 * (1 - cos(a)))
      case .hamming: return Float(0.54 - 0.46 * cos(a))
      case .blackman: return Float(0.42 - 0.5 * cos(a) + 0.08 * cos(2 * a))
      }
    }
  }

  /// Coherent gain Σw/N (Hann 0.5).
  static func coherentGain(_ w: [Float]) -> Double {
    guard !w.isEmpty else { return 0 }
    return w.reduce(0.0) { $0 + Double($1) } / Double(w.count)
  }

  /// Equivalent noise bandwidth in bins, N·Σw²/(Σw)² (Hann 1.5).
  static func equivalentNoiseBandwidth(_ w: [Float]) -> Double {
    let s1 = w.reduce(0.0) { $0 + Double($1) }
    let s2 = w.reduce(0.0) { $0 + Double($1) * Double($1) }
    guard s1 != 0 else { return .infinity }
    return Double(w.count) * s2 / (s1 * s1)
  }

  /// Scalloping loss in dB: the drop of a tone half a bin off-grid, −20·log10|W(½ bin)/W(0)|.
  /// Computed from the window's DTFT (complex-exponential input; Hann 1.4236 dB, rect 3.9224 dB).
  static func scallopingLossDB(_ w: [Float]) -> Double {
    let n = Double(w.count)
    var re = 0.0
    var im = 0.0
    var sum = 0.0
    for (k, v) in w.enumerated() {
      let a = -Double.pi * Double(k) / n
      re += Double(v) * cos(a)
      im += Double(v) * sin(a)
      sum += Double(v)
    }
    return -20 * log10((re * re + im * im).squareRoot() / sum)
  }
}

nonisolated extension RF.DSP {
  /// Level of the highest sidelobe of a window's spectrum relative to its main lobe, in dB
  /// (periodic Hann −31.47 dB, rectangular −13.26 dB), from a zero-padded FFT (`oversample`×).
  static func highestSidelobeDB(_ w: [Float], oversample: Int = 64) -> Double {
    let m = nextPowerOfTwo(w.count * max(1, oversample))
    guard let fft = RF.FFT(count: m) else { return .nan }
    var buffer = RF.IQBuffer(count: m)
    for (k, v) in w.enumerated() { buffer.i[k] = v }
    fft.forward(&buffer)
    let mag = (0..<(m / 2)).map { Double(buffer.i[$0]) * Double(buffer.i[$0]) + Double(buffer.q[$0]) * Double(buffer.q[$0]) }
    guard let peak = mag.first, peak > 0 else { return .nan }
    // Walk down the main lobe to its first minimum, then take the largest value beyond it.
    var k = 1
    while k + 1 < mag.count, mag[k + 1] < mag[k] { k += 1 }
    let side = mag[k...].max() ?? 0
    return 10 * log10(side / peak)
  }
}
