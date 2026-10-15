import Foundation

/// Coherent detection in AWGN (rf-physics C.6, Stanford EE359 lectures 9–10) and EVM (C.7).
/// Arguments are E_b/N₀ or E_s/N₀ in dB as named; results are probabilities.
nonisolated extension RF.ErrorRates {
  /// BPSK (and Gray QPSK per bit): P_b = Q(√(2E_b/N₀)). 0 dB → 7.864 960e-2; 10 dB → 3.872 108e-6.
  static func bpskBER(ebN0DB: Double) -> Double {
    RF.Special.Q((2 * pow(10, ebN0DB / 10)).squareRoot())
  }

  /// M-PSK symbol error P_s ≈ 2Q(√(2γ_s)·sin(π/M)) (8PSK at E_s/N₀ 15 dB → 2.339 45e-3).
  static func mpskSER(order m: Int, esN0DB: Double) -> Double {
    if m == 2 { return RF.Special.Q((2 * pow(10, esN0DB / 10)).squareRoot()) }
    return min(1, 2 * RF.Special.Q((2 * pow(10, esN0DB / 10)).squareRoot() * sin(Double.pi / Double(m))))
  }

  /// Square M-QAM nearest-neighbour approximation P_s ≈ 4(1 − 1/√M)·Q(√(3γ_s/(M−1)))
  /// (16QAM at E_b/N₀ 10 dB → 7.016 60e-3; 64QAM 14 dB → 1.292 40e-2; 256QAM 18 dB → 2.777 68e-2).
  static func mqamSERApprox(order m: Int, esN0DB: Double) -> Double {
    let gs = pow(10, esN0DB / 10)
    let mm = Double(m)
    return min(1, 4 * (1 - 1 / mm.squareRoot()) * RF.Special.Q((3 * gs / (mm - 1)).squareRoot()))
  }

  /// Exact square M-QAM symbol error 1 − (1 − p)², p = 2(1 − 1/√M)·Q(√(3γ_s/(M−1)))
  /// (16QAM at E_b/N₀ 10 dB → 7.004 29e-3).
  static func mqamSERExact(order m: Int, esN0DB: Double) -> Double {
    let gs = pow(10, esN0DB / 10)
    let mm = Double(m)
    let p = 2 * (1 - 1 / mm.squareRoot()) * RF.Special.Q((3 * gs / (mm - 1)).squareRoot())
    return p * (2 - p)  // 1 − (1 − p)² without cancellation at high SNR
  }

  /// Theoretical symbol error rate of a modulation at E_b/N₀ (exact square-QAM form for QAM).
  /// Nil for OOK (no reference formula).
  static func ser(_ modulation: RF.DigitalModulation, ebN0DB: Double) -> Double? {
    let k = modulation.bitsPerSymbol
    let es = RF.Noise.esN0DB(ebN0DB: ebN0DB, bitsPerSymbol: k)
    switch modulation {
    case .ook: return nil
    case .bpsk: return bpskBER(ebN0DB: ebN0DB)
    case .qpsk:
      let p = bpskBER(ebN0DB: ebN0DB)
      return p * (2 - p)
    case .psk8: return mpskSER(order: 8, esN0DB: es)
    default: return mqamSERExact(order: modulation.order, esN0DB: es)
    }
  }

  /// Theoretical bit error rate with Gray coding, P_b ≈ P_s/log2 M (exact for BPSK and QPSK).
  static func ber(_ modulation: RF.DigitalModulation, ebN0DB: Double) -> Double? {
    switch modulation {
    case .ook: return nil
    case .bpsk, .qpsk: return bpskBER(ebN0DB: ebN0DB)
    default:
      guard let ps = ser(modulation, ebN0DB: ebN0DB) else { return nil }
      return ps / Double(modulation.bitsPerSymbol)
    }
  }

  /// E_b/N₀ (dB) at which `ber(modulation)` reaches `target` (BPSK 1e-5 → 9.587 86 dB).
  static func requiredEbN0DB(_ modulation: RF.DigitalModulation, targetBER target: Double) -> Double? {
    guard modulation != .ook else { return nil }
    return RF.Numerics.bisect(-10, 60, tolerance: 1e-9) { (ber(modulation, ebN0DB: $0) ?? 1) - target }
  }

  // MARK: EVM

  /// EVM ratio → dB, 20·log10 (3.5 % → −29.119 dB).
  static func evmDB(fromRatio r: Double) -> Double { 20 * log10(r) }

  /// EVM dB → ratio (−35 dB → 1.7783 %).
  static func evmRatio(fromDB db: Double) -> Double { pow(10, db / 20) }

  /// Base-station EVM requirement of 3GPP TS 38.104 V19.6.0 Table 6.5.2.2-1 (ratio).
  /// 1024QAM is 2.5 % up to 4.2 GHz and 2.8 % above. Nil for modulations it does not list.
  static func nrEVMRequirement(_ modulation: RF.DigitalModulation, carrierFrequency f: Double = 3.5e9) -> Double? {
    switch modulation {
    case .qpsk: 0.175
    case .qam16: 0.125
    case .qam64: 0.08
    case .qam256: 0.035
    case .qam1024: f <= 4.2e9 ? 0.025 : 0.028
    default: nil
    }
  }

  /// 802.11ax 1024-QAM transmit EVM, −35 dB (NI).
  static let wifi6EVM1024DB = -35.0
}
