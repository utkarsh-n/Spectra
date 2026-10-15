import Accelerate
import Foundation

nonisolated extension RF {
  /// A block of complex baseband samples in split form (equal-length I and Q arrays), the layout
  /// vDSP works on. Value semantics; keep one buffer per stage and reuse it to avoid allocations.
  struct IQBuffer: Hashable, Sendable {
    /// In-phase (real) parts.
    var i: [Float]
    /// Quadrature (imaginary) parts.
    var q: [Float]

    /// A zero-filled buffer of `count` samples.
    init(count: Int = 0) {
      i = [Float](repeating: 0, count: count)
      q = [Float](repeating: 0, count: count)
    }

    /// Wraps existing I and Q arrays (must be the same length).
    init(i: [Float], q: [Float]) {
      precondition(i.count == q.count, "IQBuffer: I and Q lengths differ")
      self.i = i
      self.q = q
    }

    /// A real signal (Q = 0).
    init(real: [Float]) {
      i = real
      q = [Float](repeating: 0, count: real.count)
    }

    var count: Int { i.count }
    var isEmpty: Bool { i.isEmpty }

    /// Sample `n` as a double-precision complex number.
    subscript(n: Int) -> RF.Complex {
      get { RF.Complex(Double(i[n]), Double(q[n])) }
      set {
        i[n] = Float(newValue.re)
        q[n] = Float(newValue.im)
      }
    }

    /// Resizes to `count` samples (new samples are zero; existing samples are kept).
    mutating func resize(to count: Int) {
      if count < i.count {
        i.removeLast(i.count - count)
        q.removeLast(q.count - count)
      } else if count > i.count {
        i.append(contentsOf: repeatElement(0, count: count - i.count))
        q.append(contentsOf: repeatElement(0, count: count - q.count))
      }
    }

    /// Sets every sample to zero without reallocating.
    mutating func zero() {
      for n in i.indices {
        i[n] = 0
        q[n] = 0
      }
    }

    /// Appends another buffer.
    mutating func append(_ other: IQBuffer) {
      i.append(contentsOf: other.i)
      q.append(contentsOf: other.q)
    }

    /// Appends one sample.
    mutating func append(_ re: Float, _ im: Float) {
      i.append(re)
      q.append(im)
    }

    /// Samples in `range` as a new buffer.
    func slice(_ range: Range<Int>) -> IQBuffer {
      IQBuffer(i: Array(i[range]), q: Array(q[range]))
    }

    /// Mean power ⟨|x|²⟩ (0 for an empty buffer).
    var meanPower: Double {
      guard !i.isEmpty else { return 0 }
      var si: Float = 0
      var sq: Float = 0
      vDSP_svesq(i, 1, &si, vDSP_Length(i.count))
      vDSP_svesq(q, 1, &sq, vDSP_Length(q.count))
      return Double(si + sq) / Double(i.count)
    }

    /// Multiplies every sample by a real factor.
    mutating func scale(by factor: Float) {
      guard !i.isEmpty else { return }
      var f = factor
      let n = vDSP_Length(i.count)
      i.withUnsafeMutableBufferPointer { p in vDSP_vsmul(p.baseAddress!, 1, &f, p.baseAddress!, 1, n) }
      q.withUnsafeMutableBufferPointer { p in vDSP_vsmul(p.baseAddress!, 1, &f, p.baseAddress!, 1, n) }
    }

    /// Multiplies every sample by a complex factor.
    mutating func rotate(by factor: RF.Complex) {
      let a = Float(factor.re)
      let b = Float(factor.im)
      for n in i.indices {
        let x = i[n]
        let y = q[n]
        i[n] = x * a - y * b
        q[n] = x * b + y * a
      }
    }

    /// Calls `body` with a split-complex view of the samples. The buffer must not be empty.
    mutating func withSplitComplex<R>(_ body: (inout DSPSplitComplex) throws -> R) rethrows -> R {
      precondition(!i.isEmpty, "IQBuffer.withSplitComplex on an empty buffer")
      return try i.withUnsafeMutableBufferPointer { ip in
        try q.withUnsafeMutableBufferPointer { qp in
          var split = DSPSplitComplex(realp: ip.baseAddress!, imagp: qp.baseAddress!)
          return try body(&split)
        }
      }
    }

    /// Magnitudes |x[n]|.
    func magnitudes() -> [Float] {
      var out = [Float](repeating: 0, count: count)
      for n in out.indices { out[n] = (i[n] * i[n] + q[n] * q[n]).squareRoot() }
      return out
    }

    /// Phases arg x[n] in radians.
    func phases() -> [Float] {
      var out = [Float](repeating: 0, count: count)
      for n in out.indices { out[n] = atan2(q[n], i[n]) }
      return out
    }
  }
}
