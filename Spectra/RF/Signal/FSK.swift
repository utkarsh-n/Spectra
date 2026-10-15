import Foundation

nonisolated extension RF {
  /// Continuous-phase FSK family on complex baseband: plain CPFSK (rectangular frequency pulse),
  /// GFSK (Gaussian, BT given) and GMSK (h = 0.5, BT 0.3). The instantaneous frequency is
  /// ±h·R/2 for a long run of ones/zeros, so each symbol advances the phase by ±π·h
  /// (rf-physics D.4–D.5: h = 2Δf/R_b).
  struct FSKSettings: Hashable, Codable, Sendable {
    /// Modulation index h.
    var index: Double
    /// Gaussian bandwidth-time product, or nil for rectangular (plain CPFSK).
    var bt: Double?
    /// Samples per symbol in the simulation.
    var samplesPerSymbol: Int

    init(index: Double, bt: Double?, samplesPerSymbol: Int = 8) {
      self.index = index
      self.bt = bt
      self.samplesPerSymbol = samplesPerSymbol
    }

    /// GSM GMSK: h = 0.5, BT = 0.3 (TS 45.004).
    static func gmsk(samplesPerSymbol sps: Int = 8) -> FSKSettings { FSKSettings(index: 0.5, bt: 0.3, samplesPerSymbol: sps) }
    /// Bluetooth LE GFSK: h = 0.5 (0.45–0.55), BT = 0.5.
    static func bluetoothLE(samplesPerSymbol sps: Int = 8) -> FSKSettings { FSKSettings(index: 0.5, bt: 0.5, samplesPerSymbol: sps) }
    /// Bluetooth BR GFSK: h = 0.32 (0.28–0.35), BT = 0.5.
    static func bluetoothBR(samplesPerSymbol sps: Int = 8) -> FSKSettings { FSKSettings(index: 0.32, bt: 0.5, samplesPerSymbol: sps) }
  }

  /// FSK/GFSK/GMSK modulator with phase continuity across calls.
  struct FSKModulator: Sendable {
    let settings: FSKSettings
    private let pulse: [Float]
    private var phase = 0.0
    private var filter: RF.DSP.FIRFilter

    init(_ requested: FSKSettings) {
      var settings = requested
      settings.samplesPerSymbol = max(1, requested.samplesPerSymbol)
      if !settings.index.isFinite { settings.index = 0.5 }
      self.settings = settings
      if let bt = settings.bt {
        pulse = RF.DSP.gaussianTaps(bt: bt, samplesPerSymbol: settings.samplesPerSymbol, spanSymbols: 4)
      } else {
        pulse = [1]
      }
      filter = RF.DSP.FIRFilter(taps: pulse)
    }

    /// Delay of the frequency pulse filter in samples (half the Gaussian span).
    var filterDelay: Int { (pulse.count - 1) / 2 }

    mutating func reset() {
      phase = 0
      filter.reset()
    }

    /// Modulates bits (1 → +f, 0 → −f) into `bits.count × sps` unit-amplitude samples.
    mutating func modulate(bits: [UInt8], into out: inout IQBuffer) {
      let sps = settings.samplesPerSymbol
      var nrz = [Float](repeating: 0, count: bits.count * sps)
      for (b, bit) in bits.enumerated() {
        let v: Float = bit & 1 == 1 ? 1 : -1
        for k in 0..<sps { nrz[b * sps + k] = v }
      }
      let freq = filter.process(nrz)
      if out.count != freq.count { out.resize(to: freq.count) }
      let step = Double.pi * settings.index / Double(sps)
      for n in freq.indices {
        phase += step * Double(freq[n])
        if phase > Double.pi { phase -= 2 * Double.pi } else if phase < -Double.pi { phase += 2 * Double.pi }
        out.i[n] = Float(cos(phase))
        out.q[n] = Float(sin(phase))
      }
    }

    mutating func modulate(bits: [UInt8]) -> IQBuffer {
      var out = IQBuffer()
      modulate(bits: bits, into: &out)
      return out
    }
  }

  /// Non-coherent FSK receiver: a phase discriminator summed over each symbol, sign decision.
  struct FSKDemodulator: Sendable {
    let settings: FSKSettings

    init(_ settings: FSKSettings) { self.settings = settings }

    /// Bits from `samples`, where symbol k occupies samples `[offset + k·sps, offset + (k+1)·sps)`
    /// (pass the modulator's `filterDelay` as the offset).
    func demodulate(_ samples: IQBuffer, offset requestedOffset: Int = 0, symbols: Int? = nil) -> [UInt8] {
      let sps = max(1, settings.samplesPerSymbol)
      let offset = max(0, requestedOffset)
      let available = max(0, (samples.count - offset) / sps)
      let n = max(0, min(symbols ?? available, available))
      var bits = [UInt8](repeating: 0, count: n)
      for k in 0..<n {
        var acc = 0.0
        let start = offset + k * sps
        for m in start..<(start + sps) where m >= 1 {
          let re = Double(samples.i[m] * samples.i[m - 1] + samples.q[m] * samples.q[m - 1])
          let im = Double(samples.q[m] * samples.i[m - 1] - samples.i[m] * samples.q[m - 1])
          acc += atan2(im, re)
        }
        bits[k] = acc >= 0 ? 1 : 0
      }
      return bits
    }
  }
}
