import Foundation

nonisolated extension RF {
  /// Linear digital modulations with Gray mapping (rf-physics D.6, 3GPP TS 38.211 §5.1).
  enum DigitalModulation: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// On-off keying (2-ASK): bit 1 → √2, bit 0 → 0 (unit mean power).
    case ook
    case bpsk, qpsk, psk8, qam16, qam64, qam256, qam1024, qam4096

    var id: String { rawValue }

    /// Bits per symbol: BPSK 1, QPSK 2, 8PSK 3, 16QAM 4 … 4096QAM 12.
    var bitsPerSymbol: Int {
      switch self {
      case .ook, .bpsk: 1
      case .qpsk: 2
      case .psk8: 3
      case .qam16: 4
      case .qam64: 6
      case .qam256: 8
      case .qam1024: 10
      case .qam4096: 12
      }
    }

    /// Constellation size M = 2^bits.
    var order: Int { 1 << bitsPerSymbol }

    /// Square QAM (QPSK counts: it is 4-QAM with the same mapping rule in 38.211).
    var isSquareQAM: Bool { bitsPerSymbol % 2 == 0 }

    var displayName: String {
      switch self {
      case .ook: "OOK"
      case .bpsk: "BPSK"
      case .qpsk: "QPSK"
      case .psk8: "8PSK"
      case .qam16: "16-QAM"
      case .qam64: "64-QAM"
      case .qam256: "256-QAM"
      case .qam1024: "1024-QAM"
      case .qam4096: "4096-QAM"
      }
    }

    /// The square-QAM modulation of a given order (4 … 4096), if any.
    static func qam(order: Int) -> DigitalModulation? {
      switch order {
      case 4: .qpsk
      case 16: .qam16
      case 64: .qam64
      case 256: .qam256
      case 1024: .qam1024
      case 4096: .qam4096
      default: nil
      }
    }
  }

  /// Maps bits to unit-average-power symbols and back (hard decisions).
  ///
  /// Square QAM follows 38.211: even-indexed bits drive I, odd-indexed bits drive Q, and each
  /// axis is the Gray recursion `(1−2b₀)[2^{m−1} − (1−2b₂)[2^{m−2} − …]]`, normalized by
  /// √(2(M−1)/3) — so 16QAM bits 0000 → (1 + j)/√10 and 0010 → (3 + j)/√10. QPSK is
  /// `[(1−2b₀) + j(1−2b₁)]/√2`. BPSK sits on the real axis (bit 0 → +1). 8PSK places Gray code
  /// g(k) = k ⊕ (k ≫ 1) at angle 2πk/8.
  struct Constellation: Sendable {
    let modulation: DigitalModulation
    /// Points indexed by the bit pattern value (MSB first = b₀), unit average power.
    let points: [RF.Complex]
    private let pointsI: [Float]
    private let pointsQ: [Float]
    /// For square QAM: per-axis bit pattern of each amplitude level index (level −(L−1) … L−1 step 2).
    private let axisBits: [Int]
    private let axisLevels: Int
    private let scale: Double

    init(_ modulation: DigitalModulation) {
      self.modulation = modulation
      let k = modulation.bitsPerSymbol
      let m = modulation.order
      var pts = [RF.Complex](repeating: .zero, count: m)
      var axisBits: [Int] = []
      var axisLevels = 0
      var scale = 1.0
      switch modulation {
      case .ook:
        pts = [RF.Complex(0), RF.Complex(2.0.squareRoot())]
      case .bpsk:
        pts = [RF.Complex(1), RF.Complex(-1)]
      case .psk8:
        for pos in 0..<8 {
          let g = pos ^ (pos >> 1)
          pts[g] = RF.Complex.expj(2 * Double.pi * Double(pos) / 8)
        }
      default:
        let half = k / 2
        axisLevels = 1 << half
        scale = 1 / (2 * Double(m - 1) / 3).squareRoot()
        axisBits = [Int](repeating: 0, count: axisLevels)
        for pattern in 0..<axisLevels {
          let amp = Constellation.axisAmplitude(pattern: pattern, bits: half)
          axisBits[(amp + axisLevels - 1) / 2] = pattern
        }
        for value in 0..<m {
          var iPattern = 0
          var qPattern = 0
          for b in 0..<k {
            let bit = (value >> (k - 1 - b)) & 1
            if b % 2 == 0 { iPattern = (iPattern << 1) | bit } else { qPattern = (qPattern << 1) | bit }
          }
          pts[value] = RF.Complex(
            Double(Constellation.axisAmplitude(pattern: iPattern, bits: half)) * scale,
            Double(Constellation.axisAmplitude(pattern: qPattern, bits: half)) * scale)
        }
      }
      points = pts
      pointsI = pts.map { Float($0.re) }
      pointsQ = pts.map { Float($0.im) }
      self.axisBits = axisBits
      self.axisLevels = axisLevels
      self.scale = scale
    }

    /// Integer amplitude on one axis (odd, in −(2^m − 1)…2^m − 1) for an m-bit axis pattern,
    /// MSB first: s₀·[2^{m−1} − s₁·[2^{m−2} − … s_{m−1}]] with s = 1 − 2b.
    static func axisAmplitude(pattern: Int, bits m: Int) -> Int {
      func s(_ j: Int) -> Int { 1 - 2 * ((pattern >> (m - 1 - j)) & 1) }
      var t = 1
      var j = m - 1
      while j >= 1 {
        t = (1 << (m - j)) - s(j) * t
        j -= 1
      }
      return s(0) * t
    }

    /// Normalization factor of square M-QAM, 1/√(2(M−1)/3) (16QAM 1/√10, 4096QAM 1/√2730).
    static func qamNormalization(order m: Int) -> Double { 1 / (2 * Double(m - 1) / 3).squareRoot() }

    /// Number of symbols needed for `bitCount` bits.
    func symbolCount(forBits bitCount: Int) -> Int {
      let k = modulation.bitsPerSymbol
      return (bitCount + k - 1) / k
    }

    /// Maps bits (0/1, MSB first per symbol) to symbols. A trailing partial symbol is zero-padded.
    func map(bits: [UInt8], into out: inout RF.IQBuffer) {
      let k = modulation.bitsPerSymbol
      let n = symbolCount(forBits: bits.count)
      if out.count != n { out.resize(to: n) }
      var b = 0
      for s in 0..<n {
        var v = 0
        for _ in 0..<k {
          v = (v << 1) | (b < bits.count ? Int(bits[b] & 1) : 0)
          b += 1
        }
        out.i[s] = pointsI[v]
        out.q[s] = pointsQ[v]
      }
    }

    /// Maps bits to symbols (allocating variant).
    func map(bits: [UInt8]) -> RF.IQBuffer {
      var out = RF.IQBuffer()
      map(bits: bits, into: &out)
      return out
    }

    /// Hard-decision index (bit pattern value) of the point nearest to (x, y). Non-finite input
    /// (NaN from a broken upstream node) decides to a valid point instead of trapping.
    @inline(__always) func decide(_ x: Float, _ y: Float) -> Int {
      switch modulation {
      case .ook:
        return x * x + y * y > 0.5 ? 1 : 0
      case .bpsk:
        return x >= 0 ? 0 : 1
      case .psk8:
        let sector = (atan2(Double(y), Double(x)) / (2 * Double.pi / 8)).rounded()
        guard sector.isFinite else { return 0 }
        var pos = Int(sector)
        pos = ((pos % 8) + 8) % 8
        return pos ^ (pos >> 1)
      default:
        let half = modulation.bitsPerSymbol / 2
        let ip = axisBits[levelIndex(Double(x))]
        let qp = axisBits[levelIndex(Double(y))]
        var v = 0
        for j in 0..<half {
          v = (v << 1) | ((ip >> (half - 1 - j)) & 1)
          v = (v << 1) | ((qp >> (half - 1 - j)) & 1)
        }
        return v
      }
    }

    @inline(__always) private func levelIndex(_ v: Double) -> Int {
      let top = Double(axisLevels - 1)
      let a = ((v / scale + top) / 2).rounded()
      // NaN goes to the lowest level, ±∞ to the outermost ones (Int(NaN) would trap).
      guard a.isFinite else { return a > 0 ? axisLevels - 1 : 0 }
      return Int(min(max(a, 0), top))
    }

    /// Hard-decision bits for each received symbol (MSB first).
    func demap(_ symbols: RF.IQBuffer, into bits: inout [UInt8]) {
      let k = modulation.bitsPerSymbol
      let total = symbols.count * k
      if bits.count != total { bits = [UInt8](repeating: 0, count: total) }
      for s in 0..<symbols.count {
        let v = decide(symbols.i[s], symbols.q[s])
        for j in 0..<k { bits[s * k + j] = UInt8((v >> (k - 1 - j)) & 1) }
      }
    }

    /// Hard-decision bits (allocating variant).
    func demap(_ symbols: RF.IQBuffer) -> [UInt8] {
      var bits = [UInt8]()
      demap(symbols, into: &bits)
      return bits
    }

    /// The ideal point nearest to each received symbol (decision-directed reference for EVM).
    func decisions(_ symbols: RF.IQBuffer, into out: inout RF.IQBuffer) {
      if out.count != symbols.count { out.resize(to: symbols.count) }
      for s in 0..<symbols.count {
        let v = decide(symbols.i[s], symbols.q[s])
        out.i[s] = pointsI[v]
        out.q[s] = pointsQ[v]
      }
    }
  }
}
