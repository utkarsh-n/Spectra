import Foundation

nonisolated extension RF {
  /// Direct-sequence spread spectrum: each symbol is multiplied by a ±1 chip code; the receiver
  /// correlates over the code. Processing gain 10·log10(R_c/R_b) (rf-physics D.7).
  struct SpreadingCode: Hashable, Codable, Sendable {
    /// ±1 chips.
    let chips: [Float]
    let name: String

    init(chips: [Float], name: String) {
      self.chips = chips
      self.name = name
    }

    var length: Int { chips.count }

    /// Processing gain of the code length, 10·log10(L) dB (Barker-11 → 10.41 dB).
    var processingGainDB: Double { 10 * log10(Double(chips.count)) }

    /// 802.11b Barker-11: + − + + − + + + − − −.
    static let barker11 = SpreadingCode(chips: [1, -1, 1, 1, -1, 1, 1, 1, -1, -1, -1], name: "Barker-11")

    /// A maximal-length (m-) sequence of length 2ⁿ − 1 from a Fibonacci LFSR with the given
    /// feedback taps (1-based stage numbers of a primitive polynomial), all-ones initial state.
    static func mSequence(degree n: Int, taps: [Int], name: String? = nil) -> SpreadingCode {
      var state = [UInt8](repeating: 1, count: n)
      let length = (1 << n) - 1
      var chips = [Float](repeating: 0, count: length)
      for k in 0..<length {
        let out = state[n - 1]
        chips[k] = out == 0 ? 1 : -1
        var fb: UInt8 = 0
        for t in taps { fb ^= state[t - 1] }
        state.removeLast()
        state.insert(fb, at: 0)
      }
      return SpreadingCode(chips: chips, name: name ?? "m-sequence \(length)")
    }

    /// A 1023-chip m-sequence from 1 + x³ + x¹⁰ (the GPS C/A G1 register polynomial), standing in
    /// for a C/A Gold code in simulations (same length and chip rate, similar spectrum).
    static let mSequence1023 = mSequence(degree: 10, taps: [3, 10], name: "m-sequence 1023 (x¹⁰+x³+1)")

    /// A 127-chip m-sequence from 1 + x⁶ + x⁷ (short code for quick demos).
    static let mSequence127 = mSequence(degree: 7, taps: [6, 7], name: "m-sequence 127 (x⁷+x⁶+1)")

    /// Periodic autocorrelation at a chip lag, normalized to 1 at lag 0 (m-sequences: −1/L off-peak).
    func autocorrelation(lag: Int) -> Double {
      let l = chips.count
      var s = 0.0
      for k in 0..<l { s += Double(chips[k] * chips[(k + lag) % l]) }
      return s / Double(l)
    }
  }

  /// Spreads and despreads complex symbols with a chip code (one code period per symbol).
  struct DSSSSpreader: Sendable {
    let code: SpreadingCode

    init(code: SpreadingCode) { self.code = code }

    /// One chip per sample: output length = symbols × L.
    func spread(_ symbols: IQBuffer) -> IQBuffer {
      let l = code.length
      var out = IQBuffer(count: symbols.count * l)
      for s in 0..<symbols.count {
        for c in 0..<l {
          out.i[s * l + c] = symbols.i[s] * code.chips[c]
          out.q[s * l + c] = symbols.q[s] * code.chips[c]
        }
      }
      return out
    }

    /// Correlates each L-chip block with the code and divides by L (recovers the symbols; white
    /// noise power drops by L, the processing gain).
    func despread(_ chips: IQBuffer, offset requestedOffset: Int = 0) -> IQBuffer {
      let l = code.length
      guard l > 0 else { return IQBuffer() }
      let offset = max(0, requestedOffset)
      let n = max(0, (chips.count - offset) / l)
      var out = IQBuffer(count: n)
      let inv = 1 / Float(l)
      for s in 0..<n {
        var ai: Float = 0
        var aq: Float = 0
        for c in 0..<l {
          ai += chips.i[offset + s * l + c] * code.chips[c]
          aq += chips.q[offset + s * l + c] * code.chips[c]
        }
        out.i[s] = ai * inv
        out.q[s] = aq * inv
      }
      return out
    }
  }
}
