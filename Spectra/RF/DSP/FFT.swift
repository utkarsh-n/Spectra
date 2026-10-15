import Accelerate
import Foundation

nonisolated extension RF {
  /// Complex-to-complex DFT of a power-of-two length on vDSP (`vDSP_DFT_zop`, verified in
  /// iPhoneOS27.0.sdk vDSP.h). Both directions are unscaled, matching rf-physics G.1:
  /// forward `X[k] = Σ x[n]·e^{−j2πkn/N}`; `inverse(…, scaled: true)` divides by N.
  ///
  /// Thread safety: the setups are created in `init`, never mutated, and destroyed in `deinit`.
  /// vDSP documents that setups "only require read-only access", so concurrent `forward`/`inverse`
  /// calls with distinct buffers are safe — hence `@unchecked Sendable`.
  final class FFT: @unchecked Sendable {
    /// Transform length N (a power of two, ≥ 8).
    let count: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup

    /// Returns nil unless `count` is a power of two ≥ 8 (vDSP zop supports 2ⁿ, n ≥ 3).
    init?(count: Int) {
      guard count >= 8, count & (count - 1) == 0 else { return nil }
      guard let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD) else { return nil }
      guard let b = vDSP_DFT_zop_CreateSetup(f, vDSP_Length(count), .INVERSE) else {
        vDSP_DFT_DestroySetup(f)
        return nil
      }
      self.count = count
      forwardSetup = f
      inverseSetup = b
    }

    deinit {
      vDSP_DFT_DestroySetup(inverseSetup)
      vDSP_DFT_DestroySetup(forwardSetup)
    }

    /// Forward transform on raw pointers (each array holds `count` floats; output may alias input).
    func forward(
      inputReal: UnsafePointer<Float>, inputImag: UnsafePointer<Float>,
      outputReal: UnsafeMutablePointer<Float>, outputImag: UnsafeMutablePointer<Float>
    ) {
      vDSP_DFT_Execute(forwardSetup, inputReal, inputImag, outputReal, outputImag)
    }

    /// Inverse transform on raw pointers (unscaled).
    func inverse(
      inputReal: UnsafePointer<Float>, inputImag: UnsafePointer<Float>,
      outputReal: UnsafeMutablePointer<Float>, outputImag: UnsafeMutablePointer<Float>
    ) {
      vDSP_DFT_Execute(inverseSetup, inputReal, inputImag, outputReal, outputImag)
    }

    /// In-place forward transform of a buffer of exactly `count` samples.
    func forward(_ x: inout IQBuffer) {
      precondition(x.count == count, "FFT.forward: buffer length \(x.count) ≠ \(count)")
      let setup = forwardSetup
      x.withSplitComplex { s in vDSP_DFT_Execute(setup, s.realp, s.imagp, s.realp, s.imagp) }
    }

    /// In-place inverse transform; `scaled` divides by N so `inverse(forward(x)) == x`.
    func inverse(_ x: inout IQBuffer, scaled: Bool = true) {
      precondition(x.count == count, "FFT.inverse: buffer length \(x.count) ≠ \(count)")
      let setup = inverseSetup
      x.withSplitComplex { s in vDSP_DFT_Execute(setup, s.realp, s.imagp, s.realp, s.imagp) }
      if scaled { x.scale(by: 1 / Float(count)) }
    }

    /// Forward transform returning a new buffer.
    func forward(_ x: IQBuffer) -> IQBuffer {
      var y = x
      forward(&y)
      return y
    }

    /// Inverse transform returning a new buffer.
    func inverse(_ x: IQBuffer, scaled: Bool = true) -> IQBuffer {
      var y = x
      inverse(&y, scaled: scaled)
      return y
    }
  }

  /// A small pure-Swift radix-2 FFT in double precision. It is the independent oracle the tests
  /// use to cross-check vDSP, and a fallback for code that must not depend on Accelerate.
  enum ReferenceFFT {
    /// In-place transform; forward uses e^{−j2πkn/N}, inverse e^{+j…} and divides by N.
    /// `re.count` must be a power of two.
    static func transform(re: inout [Double], im: inout [Double], inverse: Bool = false) {
      let n = re.count
      precondition(n == im.count && n > 0 && n & (n - 1) == 0, "ReferenceFFT: length must be 2ⁿ")
      var j = 0
      for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 {
          j ^= bit
          bit >>= 1
        }
        j |= bit
        if i < j {
          re.swapAt(i, j)
          im.swapAt(i, j)
        }
      }
      var len = 2
      let sign = inverse ? 1.0 : -1.0
      while len <= n {
        let angle = sign * 2 * Double.pi / Double(len)
        let wr = cos(angle)
        let wi = sin(angle)
        var start = 0
        while start < n {
          var cr = 1.0
          var ci = 0.0
          for k in 0..<(len / 2) {
            let a = start + k
            let b = a + len / 2
            let tr = re[b] * cr - im[b] * ci
            let ti = re[b] * ci + im[b] * cr
            re[b] = re[a] - tr
            im[b] = im[a] - ti
            re[a] += tr
            im[a] += ti
            let ncr = cr * wr - ci * wi
            ci = cr * wi + ci * wr
            cr = ncr
          }
          start += len
        }
        len <<= 1
      }
      if inverse {
        let s = 1 / Double(n)
        for k in 0..<n {
          re[k] *= s
          im[k] *= s
        }
      }
    }
  }
}
