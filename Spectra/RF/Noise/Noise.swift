import Foundation

// MARK: - Thermal noise and noise figure (rf-physics C.1–C.3)

nonisolated extension RF.Noise {
  /// Thermal noise density kT in dBm/Hz (290 K → −173.975 19; 300 K → −173.828).
  static func densityDBmPerHz(temperature t: Double = RF.Const.T0) -> Double {
    10 * log10(RF.Const.kB * t * 1000)
  }

  /// Noise floor in dBm, N = k(T + T_e)B with T_e = (F − 1)T₀ the receiver's own noise referred
  /// to its input (rf-physics C.2). `temperature` is the source (antenna) noise temperature; at
  /// T = T₀ this is kT₀B·F = −173.975 + 10·log10 B + NF (20 MHz, NF 7 → −93.9649 dBm). A cold sky
  /// (T = 3 K) lowers only the source part: NF 1 dB in 1 MHz → −119.673 dBm, not kTB·F's −132.828.
  static func floorDBm(bandwidth b: Double, noiseFigureDB nf: Double = 0, temperature t: Double = RF.Const.T0) -> Double {
    let te = max(0, equivalentTemperature(noiseFigureDB: nf))
    return 10 * log10(RF.Const.kB * (max(0, t) + te) * 1000) + 10 * log10(b)
  }

  /// Noise factor F (linear) from a noise figure in dB.
  static func factor(noiseFigureDB nf: Double) -> Double { pow(10, nf / 10) }

  /// Equivalent noise temperature T_e = (F − 1)·T₀ (NF 1 dB → 75.09 K).
  static func equivalentTemperature(noiseFigureDB nf: Double) -> Double { (factor(noiseFigureDB: nf) - 1) * RF.Const.T0 }

  /// Noise figure (dB) of a noise temperature, 10·log10(1 + T_e/T₀).
  static func noiseFigureDB(equivalentTemperature te: Double) -> Double { 10 * log10(1 + te / RF.Const.T0) }

  /// One stage of a receive chain.
  struct Stage: Hashable, Codable, Sendable {
    var name: String
    var noiseFigureDB: Double
    var gainDB: Double

    init(_ name: String, noiseFigureDB: Double, gainDB: Double) {
      self.name = name
      self.noiseFigureDB = noiseFigureDB
      self.gainDB = gainDB
    }
  }

  /// Friis noise cascade F = F₁ + (F₂−1)/G₁ + (F₃−1)/(G₁G₂) + …, returned in dB
  /// (LNA 1 dB/20 dB + mixer 10 dB → 1.2999 dB).
  static func cascadeNoiseFigureDB(_ stages: [Stage]) -> Double {
    var f = 0.0
    var g = 1.0
    for (i, s) in stages.enumerated() {
      let fi = factor(noiseFigureDB: s.noiseFigureDB)
      f += i == 0 ? fi : (fi - 1) / g
      g *= pow(10, s.gainDB / 10)
    }
    return 10 * log10(max(f, 1))
  }

  /// SNR in dB of a received power against the noise floor of a bandwidth and noise figure.
  static func snrDB(receivedPowerDBm pr: Double, bandwidth b: Double, noiseFigureDB nf: Double) -> Double {
    pr - floorDBm(bandwidth: b, noiseFigureDB: nf)
  }

  /// Carrier-to-noise density C/N₀ in dB-Hz (GPS −128.5 dBm, NF 2 → 43.475 dB-Hz).
  static func cn0DBHz(receivedPowerDBm pr: Double, noiseFigureDB nf: Double) -> Double {
    pr - (densityDBmPerHz() + nf)
  }
}

// MARK: - Capacity (rf-physics C.4–C.5)

nonisolated extension RF.Noise {
  /// Shannon capacity C = B·log2(1 + SNR) in bit/s (20 MHz at 20 dB → 133.1642 Mbit/s); 0 for
  /// a zero bandwidth (a CW carrier carries no information), whatever its SNR.
  static func shannonCapacity(bandwidth b: Double, snrDB: Double) -> Double {
    guard b > 0 else { return 0 }
    return b * log2(1 + pow(10, snrDB / 10))
  }

  /// Spectral efficiency log2(1 + SNR), bit/s/Hz.
  static func spectralEfficiency(snrDB: Double) -> Double { log2(1 + pow(10, snrDB / 10)) }

  /// SNR (dB) needed for a capacity of `rate` in `bandwidth`.
  static func requiredSNRDB(rate: Double, bandwidth b: Double) -> Double {
    10 * log10(pow(2, rate / b) - 1)
  }

  /// The Shannon limit E_b/N₀ = ln 2 = −1.5917 dB (B → ∞).
  static let shannonLimitEbN0DB = 10 * log10(log(2.0))

  /// E_b/N₀ = SNR·B/R_b, all in dB.
  static func ebN0DB(snrDB: Double, bandwidth b: Double, bitRate rb: Double) -> Double {
    snrDB + 10 * log10(b / rb)
  }

  /// SNR = E_b/N₀·R_b/B, in dB.
  static func snrDB(ebN0DB: Double, bandwidth b: Double, bitRate rb: Double) -> Double {
    ebN0DB - 10 * log10(b / rb)
  }

  /// E_s/N₀ = E_b/N₀·log2 M, in dB.
  static func esN0DB(ebN0DB: Double, bitsPerSymbol k: Int) -> Double { ebN0DB + 10 * log10(Double(k)) }

  /// E_b/N₀ = E_s/N₀ / log2 M, in dB.
  static func ebN0DB(esN0DB: Double, bitsPerSymbol k: Int) -> Double { esN0DB - 10 * log10(Double(k)) }

  /// MIMO capacity log2 det(I + (ρ/N_t)·H·Hᴴ) in bit/s/Hz (Foschini/Telatar). `h` has N_r
  /// rows and N_t columns. At ρ = 20 dB: SISO 6.6582, I₂ 11.3449, I₄ 18.8018,
  /// [[1, 0.5], [0.5, 1]] 10.5814.
  static func mimoCapacity(channel h: [[RF.Complex]], snrDB: Double) -> Double {
    let nr = h.count
    guard nr > 0, let nt = h.first?.count, nt > 0 else { return 0 }
    let rho = pow(10, snrDB / 10) / Double(nt)
    // A = I + ρ·H·Hᴴ (N_r × N_r, Hermitian positive definite).
    var a = [[RF.Complex]](repeating: [RF.Complex](repeating: .zero, count: nr), count: nr)
    for i in 0..<nr {
      for j in 0..<nr {
        var s = RF.Complex.zero
        for k in 0..<nt { s += h[i][k] * h[j][k].conjugate }
        a[i][j] = s * rho + (i == j ? RF.Complex.one : .zero)
      }
    }
    return log2(hermitianDeterminant(a))
  }

  /// Real MIMO channel convenience.
  static func mimoCapacity(realChannel h: [[Double]], snrDB: Double) -> Double {
    mimoCapacity(channel: h.map { $0.map { RF.Complex($0) } }, snrDB: snrDB)
  }

  /// Determinant of a Hermitian positive-definite matrix by Cholesky (product of the squared
  /// diagonal of L). Returns 0 if the matrix is not positive definite.
  private static func hermitianDeterminant(_ a: [[RF.Complex]]) -> Double {
    let n = a.count
    var l = [[RF.Complex]](repeating: [RF.Complex](repeating: .zero, count: n), count: n)
    var det = 1.0
    for j in 0..<n {
      var d = a[j][j].re
      for k in 0..<j { d -= l[j][k].magnitudeSquared }
      guard d > 0 else { return 0 }
      let ljj = d.squareRoot()
      l[j][j] = RF.Complex(ljj)
      det *= d
      for i in (j + 1)..<max(j + 1, n) {
        var s = a[i][j]
        for k in 0..<j { s -= l[i][k] * l[j][k].conjugate }
        l[i][j] = s / ljj
      }
    }
    return det
  }
}
