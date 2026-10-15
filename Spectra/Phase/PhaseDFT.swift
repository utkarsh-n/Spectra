import Accelerate
import Foundation

nonisolated extension Phase {
  /// Double-precision complex DFT on vDSP (`vDSP_DFT_zop_CreateSetupD`), unscaled both ways:
  /// `.negative` computes X[q] = Σ x[n] e^{−2πiqn/N}, `.positive` computes Σ x[n] e^{+2πiqn/N}.
  /// The Wigner engine names the directions by the exponent sign because convention (C) uses
  /// e^{+2πiντ} for time and e^{−ikξ} for space.
  ///
  /// vDSP accepts N = f·2ⁿ with f ∈ {1, 3, 5, 15} and n ≥ 3 (also N = 4); `goodSize(atLeast:)`
  /// returns the next such length. Any other N ≥ 1 falls back to an exact O(N²) table DFT.
  ///
  /// Thread safety: the setups and tables are created in `init`, never mutated, and destroyed in
  /// `deinit`; vDSP setups only need read-only access, so concurrent `execute` calls with distinct
  /// buffers are safe — hence `@unchecked Sendable`.
  final class DFT: @unchecked Sendable {
    enum Sign: Sendable {
      /// e^{−2πiqn/N} (vDSP FORWARD).
      case negative
      /// e^{+2πiqn/N} (vDSP INVERSE, unscaled).
      case positive
    }

    let count: Int
    private let negativeSetup: vDSP_DFT_SetupD?
    private let positiveSetup: vDSP_DFT_SetupD?
    private let cosTable: [Double]
    private let sinTable: [Double]

    /// True when vDSP runs the transform (otherwise the exact O(N²) fallback does).
    var isAccelerated: Bool { negativeSetup != nil && positiveSetup != nil }

    init(count: Int) {
      precondition(count >= 1, "Phase.DFT needs at least one point")
      self.count = count
      var neg: vDSP_DFT_SetupD?
      var pos: vDSP_DFT_SetupD?
      if Self.isFast(count) {
        neg = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(count), .FORWARD)
        if let neg { pos = vDSP_DFT_zop_CreateSetupD(neg, vDSP_Length(count), .INVERSE) }
        if pos == nil, let n = neg {
          vDSP_DFT_DestroySetupD(n)
          neg = nil
        }
      }
      negativeSetup = neg
      positiveSetup = pos
      if neg == nil {
        let w = 2 * Double.pi / Double(count)
        cosTable = (0..<count).map { cos(w * Double($0)) }
        sinTable = (0..<count).map { sin(w * Double($0)) }
      } else {
        cosTable = []
        sinTable = []
      }
    }

    deinit {
      if let positiveSetup { vDSP_DFT_DestroySetupD(positiveSetup) }
      if let negativeSetup { vDSP_DFT_DestroySetupD(negativeSetup) }
    }

    /// True when vDSP supports length n: n = 4, or f·2ᵏ with f ∈ {1, 3, 5, 15} and k ≥ 3.
    static func isFast(_ n: Int) -> Bool {
      if n == 4 { return true }
      for f in [1, 3, 5, 15] where n % f == 0 {
        let p = n / f
        if p >= 8, p & (p - 1) == 0 { return true }
      }
      return false
    }

    /// Smallest vDSP-friendly length ≥ n (at least 8).
    static func goodSize(atLeast n: Int) -> Int {
      var best = Int.max
      for f in [1, 3, 5, 15] {
        var p = 8
        while f * p < n { p *= 2 }
        best = min(best, f * p)
      }
      return best
    }

    /// Smallest power of two ≥ n (at least 8).
    static func powerOfTwo(atLeast n: Int) -> Int {
      var p = 8
      while p < n { p *= 2 }
      return p
    }

    /// Transforms `count` complex samples. Output must not alias input.
    func execute(
      _ sign: Sign, inputReal: UnsafePointer<Double>, inputImag: UnsafePointer<Double>,
      outputReal: UnsafeMutablePointer<Double>, outputImag: UnsafeMutablePointer<Double>
    ) {
      if let setup = sign == .negative ? negativeSetup : positiveSetup {
        vDSP_DFT_ExecuteD(setup, inputReal, inputImag, outputReal, outputImag)
        return
      }
      let n = count
      let s: Double = sign == .negative ? -1 : 1
      for q in 0..<n {
        var accRe = 0.0
        var accIm = 0.0
        var idx = 0
        for j in 0..<n {
          let c = cosTable[idx]
          let sn = s * sinTable[idx]
          let xr = inputReal[j]
          let xi = inputImag[j]
          accRe += xr * c - xi * sn
          accIm += xr * sn + xi * c
          idx += q
          if idx >= n { idx -= n }
        }
        outputReal[q] = accRe
        outputImag[q] = accIm
      }
    }

    /// Array convenience (allocates). `re` and `im` must hold `count` values.
    func transform(_ sign: Sign, re: [Double], im: [Double]) -> (re: [Double], im: [Double]) {
      precondition(re.count == count && im.count == count, "Phase.DFT: wrong input length")
      var outRe = [Double](repeating: 0, count: count)
      var outIm = [Double](repeating: 0, count: count)
      re.withUnsafeBufferPointer { r in
        im.withUnsafeBufferPointer { i in
          outRe.withUnsafeMutableBufferPointer { or in
            outIm.withUnsafeMutableBufferPointer { oi in
              execute(sign, inputReal: r.baseAddress!, inputImag: i.baseAddress!, outputReal: or.baseAddress!, outputImag: oi.baseAddress!)
            }
          }
        }
      }
      return (outRe, outIm)
    }
  }

  /// Unscaled 2-D DFT of a row-major `rows × columns` complex array with independent signs per
  /// axis (rows = first index). Used for |ψ̃(k, ν)|² (k: negative sign, ν: positive sign).
  static func dft2D(
    re: [Double], im: [Double], rows: Int, columns: Int, rowSign: DFT.Sign, columnSign: DFT.Sign
  ) -> (re: [Double], im: [Double]) {
    precondition(re.count == rows * columns && im.count == rows * columns, "dft2D: wrong size")
    guard rows > 0, columns > 0 else { return ([], []) }
    var outRe = re
    var outIm = im
    let colDFT = DFT(count: columns)
    let rowDFT = DFT(count: rows)
    var bufRe = [Double](repeating: 0, count: max(rows, columns))
    var bufIm = bufRe
    var tmpRe = bufRe
    var tmpIm = bufRe
    // Along the second index (contiguous rows).
    for r in 0..<rows {
      for c in 0..<columns {
        bufRe[c] = outRe[r * columns + c]
        bufIm[c] = outIm[r * columns + c]
      }
      colDFT.execute(columnSign, inputReal: bufRe, inputImag: bufIm, outputReal: &tmpRe, outputImag: &tmpIm)
      for c in 0..<columns {
        outRe[r * columns + c] = tmpRe[c]
        outIm[r * columns + c] = tmpIm[c]
      }
    }
    // Along the first index (strided columns).
    for c in 0..<columns {
      for r in 0..<rows {
        bufRe[r] = outRe[r * columns + c]
        bufIm[r] = outIm[r * columns + c]
      }
      rowDFT.execute(rowSign, inputReal: bufRe, inputImag: bufIm, outputReal: &tmpRe, outputImag: &tmpIm)
      for r in 0..<rows {
        outRe[r * columns + c] = tmpRe[r]
        outIm[r * columns + c] = tmpIm[r]
      }
    }
    return (outRe, outIm)
  }
}
