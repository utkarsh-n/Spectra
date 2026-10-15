import Foundation

nonisolated extension RF {
  /// Impedance mismatch of a load on a line of characteristic impedance Z₀ (rf-physics A.16,
  /// Nikolova L04 eq. 4.28–4.30): Γ = (Z_L − Z₀)/(Z_L + Z₀), VSWR = (1+|Γ|)/(1−|Γ|),
  /// RL = −20·log10|Γ|, ML = −10·log10(1−|Γ|²), e_r = 1 − |Γ|².
  ///
  /// 73 Ω on 50 Ω → Γ 0.186 99, VSWR 1.4600, RL 14.564 dB, ML 0.1546 dB.
  struct Mismatch: Hashable, Sendable {
    /// Load impedance Z_L, Ω.
    let load: RF.Complex
    /// Reference impedance Z₀, Ω.
    let reference: Double
    /// Reflection coefficient Γ.
    let gamma: RF.Complex
    /// True when only the resistive part of Z_L is known. Any reactance raises |Γ|, so then
    /// |Γ|, VSWR and the mismatch loss are lower bounds (and the return loss an upper bound).
    let isResistiveOnly: Bool

    /// An infinite load (a thin-wire dipole at L = nλ) reflects totally: Γ = 1.
    init(load: RF.Complex, reference z0: Double = 50, resistiveOnly: Bool = false) {
      self.load = load
      reference = z0
      gamma = load.re.isInfinite || load.im.isInfinite ? RF.Complex.one : (load - RF.Complex(z0)) / (load + RF.Complex(z0))
      isResistiveOnly = resistiveOnly
    }

    /// Mismatch of a purely resistive load.
    init(resistance r: Double, reference z0: Double = 50, resistiveOnly: Bool = false) {
      self.init(load: RF.Complex(r), reference: z0, resistiveOnly: resistiveOnly)
    }

    /// |Γ|.
    var gammaMagnitude: Double { gamma.magnitude }

    /// Voltage standing-wave ratio (∞ for a total reflection).
    var vswr: Double {
      let g = gammaMagnitude
      return g >= 1 ? .infinity : (1 + g) / (1 - g)
    }

    /// Return loss −20·log10|Γ| in dB (∞ for a perfect match).
    var returnLossDB: Double { -20 * log10(gammaMagnitude) }

    /// Mismatch loss −10·log10(1 − |Γ|²) in dB (∞ for a total reflection).
    var mismatchLossDB: Double {
      let accepted = 1 - gamma.magnitudeSquared
      return accepted > 0 ? -10 * log10(accepted) : .infinity
    }

    /// Reflection (mismatch) efficiency e_r = 1 − |Γ|².
    var reflectionEfficiency: Double { max(0, 1 - gamma.magnitudeSquared) }
  }
}
