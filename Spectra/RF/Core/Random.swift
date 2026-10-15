import Foundation

nonisolated extension RF {
  /// A small, seeded, platform-independent generator (xoshiro256** seeded through SplitMix64).
  /// Every random process in the engine (bits, noise, fading phases, shadowing) draws from one of
  /// these so a simulation is reproducible from its seed. Value type: copy it to fork a stream.
  struct SeededRandom: RandomNumberGenerator, Sendable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64
    private var spare: Double?

    init(seed: UInt64) {
      var x = seed
      func splitMix(_ x: inout UInt64) -> UInt64 {
        x &+= 0x9E37_79B9_7F4A_7C15
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
      }
      s0 = splitMix(&x)
      s1 = splitMix(&x)
      s2 = splitMix(&x)
      s3 = splitMix(&x)
      spare = nil
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 { (x << k) | (x >> (64 - k)) }

    mutating func next() -> UInt64 {
      let result = Self.rotl(s1 &* 5, 7) &* 9
      let t = s1 << 17
      s2 ^= s0
      s3 ^= s1
      s1 ^= s2
      s0 ^= s3
      s2 ^= t
      s3 = Self.rotl(s3, 45)
      return result
    }

    /// Uniform double in [0, 1) with 53 random bits.
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// Uniform double in [a, b).
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }

    /// Standard normal draw (Marsaglia polar method; the second value of each pair is cached).
    mutating func gaussian() -> Double {
      if let s = spare {
        spare = nil
        return s
      }
      let (a, b) = gaussianPair()
      spare = b
      return a
    }

    /// Two independent standard normal draws.
    mutating func gaussianPair() -> (Double, Double) {
      while true {
        let u = 2 * uniform() - 1
        let v = 2 * uniform() - 1
        let s = u * u + v * v
        if s > 0, s < 1 {
          let m = (-2 * log(s) / s).squareRoot()
          return (u * m, v * m)
        }
      }
    }

    /// `count` random bits (0 or 1), 64 per generator call.
    mutating func bits(_ count: Int) -> [UInt8] {
      var out = [UInt8](repeating: 0, count: count)
      fillBits(&out)
      return out
    }

    /// Overwrites `buffer` with random bits.
    mutating func fillBits(_ buffer: inout [UInt8]) {
      var word: UInt64 = 0
      var left = 0
      for n in buffer.indices {
        if left == 0 {
          word = next()
          left = 64
        }
        buffer[n] = UInt8(word & 1)
        word >>= 1
        left -= 1
      }
    }
  }
}
