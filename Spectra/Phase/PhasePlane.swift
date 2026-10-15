import Foundation

nonisolated extension Phase {
  /// What a `Plane` holds (for labels and the provenance line).
  enum PlaneKind: String, Sendable, Hashable, Codable {
    case wigner
    case pseudoWigner
    case smoothedPseudoWigner
    case spectrogram
    case closedForm
    case fresnelSheared

    var title: String {
      switch self {
      case .wigner: "Wigner–Ville"
      case .pseudoWigner: "Pseudo-Wigner"
      case .smoothedPseudoWigner: "Smoothed pseudo-Wigner"
      case .spectrogram: "Spectrogram"
      case .closedForm: "Closed form"
      case .fresnelSheared: "Fresnel-sheared Wigner"
      }
    }

    /// Only the unsmoothed Wigner has exact marginals (rule 5).
    var hasExactMarginals: Bool { self == .wigner || self == .closedForm }
  }

  /// A phase-plane image: rows = time (or space), columns = ν (or k), row-major Double values.
  /// Signed: Wigner values are negative where cross terms interfere, so keep the sign for the
  /// diverging map (positive warm, negative cool). `floatValues()`/`signedUnit()` are the display
  /// boundary.
  ///
  /// Measures: `rowMeasure` is Δt (or Δx) per row, `columnMeasure` is dν (or dk/2π) per column,
  /// so `rowMarginal()` ≈ |z(t)|² (M1) and `columnMarginal()` ≈ |Z(ν)|² (M2).
  struct Plane: Sendable, Hashable {
    var kind: PlaneKind
    var domain: Domain
    var rowAxis: Axis
    var columnAxis: Axis
    var band: Band
    var values: [Double]
    var rowMeasure: Double
    var columnMeasure: Double
    /// Largest |Im| of the lag DFT relative to the largest |Re| (reality check; ≈ 1e-16).
    var imaginaryResidual: Double
    /// Sample index of each row in the source record (rows may be strided).
    var rowIndices: [Int]
    /// True when the lag window covered the whole record and every sample is a row, so the
    /// time marginal equals the aliased spectrum to round-off.
    var coversRecord: Bool

    var rows: Int { rowAxis.count }
    var columns: Int { columnAxis.count }
    var isEmpty: Bool { values.isEmpty }

    @inline(__always) func value(row r: Int, column c: Int) -> Double { values[r * columns + c] }

    var minValue: Double { values.min() ?? 0 }
    var maxValue: Double { values.max() ?? 0 }
    /// max |value| (the symmetric diverging-map scale).
    var absMax: Double { values.reduce(0) { max($0, abs($1)) } }

    /// Values as Float for textures (row-major rows × columns).
    func floatValues() -> [Float] { values.map { Float($0) } }

    /// Values / max|value| in [−1, 1] (sign kept) for the diverging map.
    func signedUnit() -> [Float] {
      let s = absMax
      guard s > 0 else { return [Float](repeating: 0, count: values.count) }
      return values.map { Float($0 / s) }
    }

    /// One row (all columns).
    func row(_ r: Int) -> [Double] { Array(values[(r * columns)..<((r + 1) * columns)]) }
    /// One column (all rows).
    func column(_ c: Int) -> [Double] { (0..<rows).map { values[$0 * columns + c] } }

    /// Σ over columns · dν: M1, ≈ |z(t_row)|² (exact for the Wigner and pseudo-Wigner).
    func rowMarginal() -> [Double] {
      (0..<rows).map { r in
        var s = 0.0
        for c in 0..<columns { s += values[r * columns + c] }
        return s * columnMeasure
      }
    }

    /// Σ over rows · Δt: M2, ≈ |Z(ν)|² (exact alias identity when `coversRecord`).
    func columnMarginal() -> [Double] {
      var out = [Double](repeating: 0, count: columns)
      for r in 0..<rows {
        for c in 0..<columns { out[c] += values[r * columns + c] }
      }
      return out.map { $0 * rowMeasure }
    }

    /// Σ W · Δt · dν (P: the record energy).
    var total: Double { values.reduce(0, +) * rowMeasure * columnMeasure }

    /// Σ W_a W_b Δt dν (the Moyal inner product of two planes on the same grid).
    func innerProduct(_ other: Plane) -> Double {
      precondition(values.count == other.values.count, "innerProduct: planes differ in size")
      var s = 0.0
      for i in 0..<values.count { s += values[i] * other.values[i] }
      return s * rowMeasure * columnMeasure
    }

    /// Adjacent columns averaged in groups of `factor` (the axis step grows by `factor`). The
    /// row marginal is preserved exactly, so a 4096-bin Wigner–Ville can be shown on 256 columns.
    func binnedColumns(_ factor: Int) -> Plane {
      guard factor > 1, columns % factor == 0 else { return self }
      let nc = columns / factor
      var out = [Double](repeating: 0, count: rows * nc)
      let inv = 1 / Double(factor)
      for r in 0..<rows {
        for c in 0..<nc {
          var s = 0.0
          for j in 0..<factor { s += values[r * columns + c * factor + j] }
          out[r * nc + c] = s * inv
        }
      }
      var p = self
      p.values = out
      p.columnAxis = Axis(
        start: columnAxis.start + Double(factor - 1) * columnAxis.step / 2, step: columnAxis.step * Double(factor), count: nc)
      p.columnMeasure = columnMeasure * Double(factor)
      return p
    }

    /// Index of the column nearest to value v (ν or k).
    func columnIndex(_ v: Double) -> Int { columnAxis.nearestIndex(v) }
    /// Index of the row nearest to value v (t or x).
    func rowIndex(_ v: Double) -> Int { rowAxis.nearestIndex(v) }
  }

  /// A 3-D block (x, t, ν) or (x, t, k) for the Φ volume, row-major in (a, b, c).
  struct Cube: Sendable, Hashable {
    var axisA: Axis
    var axisB: Axis
    var axisC: Axis
    var labels: [String]
    var values: [Double]

    @inline(__always) func index(_ a: Int, _ b: Int, _ c: Int) -> Int { (a * axisB.count + b) * axisC.count + c }
    @inline(__always) func value(_ a: Int, _ b: Int, _ c: Int) -> Double { values[index(a, b, c)] }
    var minValue: Double { values.min() ?? 0 }
    var maxValue: Double { values.max() ?? 0 }
    var absMax: Double { values.reduce(0) { max($0, abs($1)) } }
    func floatValues() -> [Float] { values.map { Float($0) } }
    func signedUnit() -> [Float] {
      let s = absMax
      guard s > 0 else { return [Float](repeating: 0, count: values.count) }
      return values.map { Float($0 / s) }
    }
  }
}
