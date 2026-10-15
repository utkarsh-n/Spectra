import Foundation

nonisolated extension RF.DSP {
  /// Root-raised-cosine taps, `span` symbols long at `samplesPerSymbol`, roll-off β, normalized to
  /// unit energy so a transmit/receive RRC pair is a Nyquist (zero-ISI) raised cosine with peak 1.
  /// β is clamped to 0…1 (NaN → 0.35); sps and span to ≥ 1.
  static func rootRaisedCosine(rolloff requestedBeta: Double, samplesPerSymbol requestedSPS: Int, spanSymbols requestedSpan: Int) -> [Float] {
    let beta = requestedBeta.isFinite ? min(max(requestedBeta, 0), 1) : 0.35
    let sps = max(1, requestedSPS)
    let span = max(1, requestedSpan)
    let n = span * sps + 1
    let mid = Double(n - 1) / 2
    var h = (0..<n).map { k -> Double in
      let t = (Double(k) - mid) / Double(sps)
      if t == 0 { return 1 - beta + 4 * beta / Double.pi }
      if beta > 0, abs(abs(t) - 1 / (4 * beta)) < 1e-9 {
        let a = Double.pi / (4 * beta)
        return beta / 2.0.squareRoot() * ((1 + 2 / Double.pi) * sin(a) + (1 - 2 / Double.pi) * cos(a))
      }
      let num = sin(Double.pi * t * (1 - beta)) + 4 * beta * t * cos(Double.pi * t * (1 + beta))
      let den = Double.pi * t * (1 - pow(4 * beta * t, 2))
      return num / den
    }
    let energy = h.reduce(0) { $0 + $1 * $1 }
    let s = 1 / energy.squareRoot()
    h = h.map { $0 * s }
    return h.map { Float($0) }
  }

  /// GMSK/GFSK Gaussian frequency-pulse taps from 3GPP TS 45.004 §2:
  /// h(t) = exp(−t²/(2δ²T²))/(√(2π)·δT), δ = √(ln 2)/(2π·BT). Taps sum to 1 (unity DC gain),
  /// so the constant prefactor is dropped. The limits stay finite: BT → ∞ is no filtering (one
  /// centre tap), BT → 0 (or NaN) a flat average over the span.
  static func gaussianTaps(bt: Double, samplesPerSymbol requestedSPS: Int, spanSymbols requestedSpan: Int = 4) -> [Float] {
    let sps = max(1, requestedSPS)
    let span = max(1, requestedSpan)
    let delta = RF.AnalogTheory.gaussianDelta(bt: abs(bt))
    let n = span * sps + 1
    let mid = Double(n - 1) / 2
    var h = (0..<n).map { k -> Double in
      let t = (Double(k) - mid) / Double(sps)
      if delta == 0 { return k == (n - 1) / 2 ? 1 : 0 }
      if !delta.isFinite { return 1 }
      return exp(-t * t / (2 * delta * delta))
    }
    let sum = h.reduce(0, +)
    h = h.map { $0 / sum }
    return h.map { Float($0) }
  }
}

nonisolated extension RF {
  /// Transmit pulse shaping (zero-stuffing + FIR) and matched-filter reception for linear
  /// modulations. With RRC on both sides the decimated output equals the input symbols.
  struct PulseShaper: Sendable {
    let samplesPerSymbol: Int
    let taps: [Float]
    /// Total delay through transmit + receive filters, in samples.
    var pairDelay: Int { taps.count - 1 }

    /// RRC pulse shaper (β default 0.35, span 8 symbols).
    init(samplesPerSymbol sps: Int, rolloff: Double = 0.35, spanSymbols: Int = 8) {
      samplesPerSymbol = max(1, sps)
      taps = RF.DSP.rootRaisedCosine(rolloff: rolloff, samplesPerSymbol: samplesPerSymbol, spanSymbols: spanSymbols)
    }

    /// Rectangular (NRZ) pulse shaper, `sps` ones scaled to unit energy.
    init(rectangularSamplesPerSymbol sps: Int) {
      samplesPerSymbol = max(1, sps)
      taps = [Float](repeating: 1 / Float(samplesPerSymbol).squareRoot(), count: samplesPerSymbol)
    }

    /// Up-samples and filters symbols; output length = symbols × sps (the filter tail is cut,
    /// the leading transient is part of the output). Scaled so unit-power symbols give unit-power
    /// samples on average.
    func shape(_ symbols: RF.IQBuffer) -> RF.IQBuffer {
      let up = RF.DSP.zeroStuff(symbols, factor: samplesPerSymbol)
      var filter = RF.DSP.ComplexFIRFilter(taps: taps)
      var y = filter.process(up)
      y.scale(by: Float(samplesPerSymbol).squareRoot())
      return y
    }

    /// Matched filter + decimation. `offset` is the sampling phase; the default skips the combined
    /// filter delay. Returns the symbols whose full pulse lies inside the block.
    func receive(_ samples: RF.IQBuffer, offset: Int? = nil) -> RF.IQBuffer {
      var filter = RF.DSP.ComplexFIRFilter(taps: taps)
      var y = filter.process(samples)
      y.scale(by: 1 / Float(samplesPerSymbol).squareRoot())
      let start = max(0, offset ?? pairDelay)
      var out = RF.IQBuffer()
      var n = start
      while n < y.count {
        out.append(y.i[n], y.q[n])
        n += samplesPerSymbol
      }
      return out
    }
  }
}
