import Foundation
import simd

nonisolated extension RF {
  /// How a pattern magnitude becomes a lobe radius.
  enum PatternScale: Hashable, Codable, Sendable {
    /// Radius = |F| (field pattern).
    case field
    /// Radius = |F|² (power pattern; shrinks sidelobes).
    case power
    /// Radius = max(0, 1 + 20·log10|F| / |floorDB|): 0 dB at the rim, `floorDB` at the centre.
    case decibel(floorDB: Double)

    /// Maps a normalized field magnitude to a radius in 0…1.
    func radius(_ f: Double) -> Double {
      switch self {
      case .field: return f
      case .power: return f * f
      case .decibel(let floor):
        guard f > 0 else { return 0 }
        return max(0, 1 + 20 * log10(f) / abs(floor))
      }
    }
  }

  /// A latitude–longitude grid of the normalized pattern |F| over the whole sphere, in the
  /// antenna's local frame, for the 3D lobe (lit wire mesh). Row i is the ring at polar angle
  /// θᵢ (row 0 = +z pole, last row = −z pole); column j is azimuth φⱼ = 2πj/columns (no
  /// duplicated seam column; wrap j = columns → 0 when drawing).
  struct PatternMesh: Sendable {
    let rows: Int
    let columns: Int
    /// Polar angles θᵢ of the rows, radians.
    let thetas: [Double]
    /// |F| per vertex, row-major, 0…1.
    let values: [Float]

    /// Samples a model. `focus` > 1 crowds rows toward +z (θᵢ = π·tᵢ^focus) so narrow
    /// beams along +z (dish, horn, helix) get enough rings; use `suggestedFocus(for:)`.
    init(model: AntennaModel, rows: Int = 91, columns: Int = 120, focus: Double = 1) {
      let r = max(3, rows)
      let c = max(3, columns)
      self.rows = r
      self.columns = c
      let thetas = (0..<r).map { i in Double.pi * pow(Double(i) / Double(r - 1), max(1, focus)) }
      self.thetas = thetas
      var v = [Float](repeating: 0, count: r * c)
      for i in 0..<r {
        let st = sin(thetas[i])
        let ct = cos(thetas[i])
        for j in 0..<c {
          let phi = 2 * Double.pi * Double(j) / Double(c)
          v[i * c + j] = Float(model.field(SIMD3(st * cos(phi), st * sin(phi), ct)))
        }
      }
      values = v
    }

    /// A focus exponent that gives the main beam about six rings when it points along +z.
    static func suggestedFocus(for model: AntennaModel, rows: Int = 91) -> Double {
      guard model.peakDirection.z > 0.99, let bw = model.ePlaneHPBWDeg else { return 1 }
      let uniformStep = 180 / Double(max(rows - 1, 1))
      let want = bw / 2 / 6
      guard want < uniformStep else { return 1 }
      // First ring at π·(1/(r−1))^focus ≈ want → focus = log(want/180)/log(1/(r−1)).
      let f = log(want / 180) / log(1 / Double(max(rows - 1, 2)))
      return min(4, max(1, f))
    }

    /// |F| at row i, column j (column wraps).
    func value(row i: Int, column j: Int) -> Float { values[i * columns + ((j % columns) + columns) % columns] }

    /// Unit direction of a vertex.
    func direction(row i: Int, column j: Int) -> SIMD3<Float> {
      let t = thetas[i]
      let phi = 2 * Double.pi * Double(j) / Double(columns)
      return SIMD3(Float(sin(t) * cos(phi)), Float(sin(t) * sin(phi)), Float(cos(t)))
    }

    /// Vertex positions (radius from `scale` × direction), row-major like `values`.
    func positions(scale: PatternScale = .field) -> [SIMD3<Float>] {
      var out = [SIMD3<Float>](repeating: .zero, count: values.count)
      for i in 0..<rows {
        for j in 0..<columns {
          let k = i * columns + j
          out[k] = direction(row: i, column: j) * Float(scale.radius(Double(values[k])))
        }
      }
      return out
    }
  }

  /// A planar cut of the pattern for the polar plots.
  struct PatternCut: Sendable {
    /// Angles α in degrees from the peak, −180 ..< 180.
    let anglesDeg: [Double]
    /// |F| at each angle (0…1).
    let values: [Double]

    /// Values in dB (20·log10|F|), floored.
    func decibels(floorDB: Double = -40) -> [Double] { values.map { $0 > 0 ? max(floorDB, 20 * log10($0)) : floorDB } }
  }

  /// Which principal plane to cut.
  enum PatternPlane: String, CaseIterable, Codable, Hashable, Sendable {
    case e, h

    var displayName: String { self == .e ? "E-plane" : "H-plane" }
  }
}

nonisolated extension RF.AntennaModel {
  /// Samples the E- or H-plane through the peak: direction(α) = cosα·peak + sinα·axis.
  func cut(_ plane: RF.PatternPlane, count: Int = 361) -> RF.PatternCut {
    let axis = plane == .e ? ePlaneAxis : hPlaneAxis
    let n = max(4, count)
    var angles = [Double](repeating: 0, count: n)
    var values = [Double](repeating: 0, count: n)
    for k in 0..<n {
      let a = -180 + 360 * Double(k) / Double(n)
      let r = a * Double.pi / 180
      angles[k] = a
      values[k] = field(cos(r) * peakDirection + sin(r) * axis)
    }
    return RF.PatternCut(anglesDeg: angles, values: values)
  }
}

// MARK: - Pose (Follow phone / Beam lock)

nonisolated extension RF.AntennaModel {
  /// The link toward a world-frame direction for an antenna whose local frame is rotated by
  /// `attitude` (local → world, e.g. the phone's attitude quaternion), split into its two
  /// mechanisms (gyre-integration §4.2): the pattern toward the direction (dB relative to the
  /// peak) and the polarization mismatch against a reference antenna there facing back, whose
  /// "vertical" is world `up`. `gainDB` is the headline gain plus the pattern term.
  ///
  /// A vertical λ/2 dipole rolled 60° about the line of sight: pattern 0 dB, polarization
  /// −6.02 dB. Pitched 60° toward the source: pattern −7.58 dB, polarization 0 dB.
  func linkFactor(
    attitude: simd_quatd, toward world: SIMD3<Double>, reference: RF.ReferencePolarization, up: SIMD3<Double> = SIMD3(0, 0, 1),
    floorDB: Double = -60
  ) -> (patternDB: Double, polarizationDB: Double, gainDB: Double) {
    let w = simd_normalize(world)
    let local = RF.AntennaModel.localDirection(world: w, attitude: attitude)
    let pattern = max(floorDB, 10 * log10(max(power(local), 1e-300)))
    let polWorld = polarization(local).rotated(by: attitude)
    let plf = polWorld.plf(with: reference.vector(propagation: -w, up: up))
    let polarization = max(floorDB, 10 * log10(max(plf, 1e-300)))
    return (pattern, polarization, gainDBi + pattern)
  }
}
