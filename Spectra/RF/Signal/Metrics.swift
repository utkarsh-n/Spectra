import Foundation

nonisolated extension RF {
  /// Error-vector magnitude of received symbols against reference symbols (rf-physics C.7):
  /// EVM_rms = √(Σ|e|²/Σ|s_ref|²), EVM_dB = 20·log10 EVM_rms.
  struct EVMResult: Hashable, Sendable {
    /// RMS EVM as a ratio (0.035 = 3.5 %).
    let rms: Double
    var percent: Double { rms * 100 }
    var dB: Double { 20 * log10(max(rms, 1e-12)) }
    /// Noise-limited SNR estimate ≈ −EVM_dB (ignores phase noise and nonlinearity).
    var estimatedSNRDB: Double { -dB }
    /// Number of symbols measured.
    let count: Int

    static func measure(received rx: IQBuffer, reference ref: IQBuffer) -> EVMResult {
      let n = min(rx.count, ref.count)
      var err = 0.0
      var sig = 0.0
      for k in 0..<n {
        let ei = Double(rx.i[k] - ref.i[k])
        let eq = Double(rx.q[k] - ref.q[k])
        err += ei * ei + eq * eq
        sig += Double(ref.i[k] * ref.i[k] + ref.q[k] * ref.q[k])
      }
      return EVMResult(rms: sig > 0 ? (err / sig).squareRoot() : 0, count: n)
    }
  }

  /// Accumulates bit errors across frames.
  struct BERCounter: Hashable, Sendable {
    private(set) var bits = 0
    private(set) var errors = 0

    init() {}

    /// Counts differences between sent and received bits over their common length.
    mutating func add(sent: [UInt8], received: [UInt8]) {
      let n = min(sent.count, received.count)
      var e = 0
      for k in 0..<n where (sent[k] ^ received[k]) & 1 != 0 { e += 1 }
      bits += n
      errors += e
    }

    /// Bit error ratio (0 when nothing was counted).
    var ber: Double { bits > 0 ? Double(errors) / Double(bits) : 0 }

    /// Upper 95 % bound on BER when no errors were seen yet ("rule of three": 3/N).
    var ruleOfThreeBound: Double? { errors == 0 && bits > 0 ? 3 / Double(bits) : nil }

    mutating func reset() {
      bits = 0
      errors = 0
    }
  }
}
