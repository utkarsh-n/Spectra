import Accelerate
import Foundation

// MARK: - Oscillator and mixer

nonisolated extension RF.DSP {
  /// A numerically controlled oscillator e^{j2πft}: generates a complex tone or frequency-shifts
  /// a block (the Patch "Mixer" node). Phase continues across calls.
  struct NCO: Hashable, Sendable {
    var frequency: Double
    let sampleRate: Double
    private(set) var phase = 0.0

    init(frequency: Double, sampleRate: Double, phase: Double = 0) {
      self.frequency = frequency
      self.sampleRate = sampleRate
      self.phase = phase
    }

    /// The next `count` samples of e^{jφ}.
    mutating func generate(count: Int) -> RF.IQBuffer {
      var out = RF.IQBuffer(count: count)
      let step = 2 * Double.pi * frequency / sampleRate
      for n in 0..<count {
        out.i[n] = Float(cos(phase))
        out.q[n] = Float(sin(phase))
        phase += step
      }
      phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
      return out
    }

    /// Multiplies a block by e^{j2πft} in place (shifts its spectrum up by f).
    mutating func mix(_ x: inout RF.IQBuffer) {
      let step = 2 * Double.pi * frequency / sampleRate
      for n in 0..<x.count {
        let c = Float(cos(phase))
        let s = Float(sin(phase))
        let re = x.i[n] * c - x.q[n] * s
        let im = x.i[n] * s + x.q[n] * c
        x.i[n] = re
        x.q[n] = im
        phase += step
      }
      phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
    }

    /// Multiplies a real block by cos(2πft + φ) (a real mixer / product modulator).
    mutating func mixReal(_ x: inout [Float]) {
      let step = 2 * Double.pi * frequency / sampleRate
      for n in x.indices {
        x[n] *= Float(cos(phase))
        phase += step
      }
      phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
    }
  }

  /// Peak envelope follower with separate attack and release time constants (Gyre's conditioner).
  struct EnvelopeFollower: Hashable, Sendable {
    let attack: Double
    let release: Double
    private var level = 0.0

    /// Time constants in seconds at `sampleRate`.
    init(attack: Double, release: Double, sampleRate: Double) {
      self.attack = attack > 0 ? 1 - exp(-1 / (attack * sampleRate)) : 1
      self.release = release > 0 ? 1 - exp(-1 / (release * sampleRate)) : 1
    }

    mutating func reset() { level = 0 }

    /// Follows |x| sample by sample.
    mutating func process(_ x: [Float]) -> [Float] {
      var out = [Float](repeating: 0, count: x.count)
      for n in x.indices {
        let a = Double(abs(x[n]))
        level += (a > level ? attack : release) * (a - level)
        out[n] = Float(level)
      }
      return out
    }
  }
}

// MARK: - Streaming rate change

nonisolated extension RF.DSP {
  /// Integer-factor interpolator for real streams: zero-stuffs by L and low-pass filters at
  /// 0.45/L with gain L (Blackman windowed sinc). Seamless across blocks.
  struct Interpolator: Sendable {
    let factor: Int
    private var filter: FIRFilter
    private var stuffed: [Float] = []

    init(factor: Int, tapsPerPhase: Int = 16) {
      self.factor = max(1, factor)
      let taps = RF.DSP.firTaps(.lowpass, cutoff: 0.45 / Double(self.factor), taps: tapsPerPhase * self.factor + 1)
      filter = FIRFilter(taps: taps.map { $0 * Float(max(1, factor)) })
    }

    /// Group delay in output samples.
    var delay: Double { filter.delay }

    mutating func reset() { filter.reset() }

    /// `x.count × factor` output samples.
    mutating func process(_ x: [Float]) -> [Float] {
      guard factor > 1 else { return x }
      let n = x.count * factor
      if stuffed.count != n { stuffed = [Float](repeating: 0, count: n) } else { for k in stuffed.indices { stuffed[k] = 0 } }
      for k in x.indices { stuffed[k * factor] = x[k] }
      return filter.process(stuffed)
    }
  }

  /// Integer-factor decimator for real streams: low-pass at 0.45/M, then keeps every M-th
  /// sample. Seamless across blocks (filter history and decimation phase carry over).
  struct Decimator: Sendable {
    let factor: Int
    private var filter: FIRFilter
    private var phase = 0

    init(factor: Int, tapsPerPhase: Int = 16) {
      self.factor = max(1, factor)
      filter = FIRFilter(taps: RF.DSP.firTaps(.lowpass, cutoff: 0.45 / Double(self.factor), taps: tapsPerPhase * self.factor + 1))
    }

    /// Group delay in input samples.
    var delay: Double { filter.delay }

    mutating func reset() {
      filter.reset()
      phase = 0
    }

    mutating func process(_ x: [Float]) -> [Float] {
      guard factor > 1 else { return x }
      let y = filter.process(x)
      var out: [Float] = []
      out.reserveCapacity(x.count / factor + 1)
      var k = phase
      while k < y.count {
        out.append(y[k])
        k += factor
      }
      phase = k - y.count
      return out
    }
  }
}

// MARK: - Bits

nonisolated extension RF {
  /// Bit helpers for the message sources.
  enum Bits {
    /// UTF-8 bytes of a string, MSB first.
    static func fromText(_ text: String) -> [UInt8] {
      var out: [UInt8] = []
      out.reserveCapacity(text.utf8.count * 8)
      for byte in text.utf8 {
        for b in (0..<8).reversed() { out.append((byte >> UInt8(b)) & 1) }
      }
      return out
    }

    /// Decodes whole bytes (MSB first) as UTF-8, replacing invalid sequences.
    static func toText(_ bits: [UInt8]) -> String {
      var bytes: [UInt8] = []
      var k = 0
      while k + 8 <= bits.count {
        var v: UInt8 = 0
        for j in 0..<8 { v = (v << 1) | (bits[k + j] & 1) }
        bytes.append(v)
        k += 8
      }
      return String(decoding: bytes, as: UTF8.self)
    }

    /// Number of positions where two bit arrays differ (over the common length).
    static func errors(_ a: [UInt8], _ b: [UInt8]) -> Int {
      var e = 0
      for k in 0..<min(a.count, b.count) where (a[k] ^ b[k]) & 1 != 0 { e += 1 }
      return e
    }
  }
}

// MARK: - Plot helpers

nonisolated extension RF.IQBuffer {
  /// Samples as SIMD2 points (I, Q) for `ConstellationPlot`.
  var points: [SIMD2<Float>] {
    var out = [SIMD2<Float>](repeating: .zero, count: count)
    for n in 0..<count { out[n] = SIMD2(i[n], q[n]) }
    return out
  }

  /// Every `stride`-th sample as points (thinning for dense plots).
  func points(stride s: Int) -> [SIMD2<Float>] {
    let step = max(1, s)
    return Swift.stride(from: 0, to: count, by: step).map { SIMD2(i[$0], q[$0]) }
  }
}
