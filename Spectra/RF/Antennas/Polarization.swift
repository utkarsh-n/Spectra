import Foundation
import simd

nonisolated extension RF {
  /// A far-field polarization as a complex 3-vector e = re + j·im (perpendicular to the
  /// propagation direction). Antennas report the polarization they *transmit* toward a direction.
  ///
  /// Polarization loss factor between a wave and a receiving antenna (rf-physics A.15):
  /// with the wave's vector e_w (travelling from source to receiver) and the receiver's own
  /// transmit polarization e_a (pointing back toward the source), PLF = |e_w · e_a|² /(|e_w|²|e_a|²)
  /// with no conjugation. This gives co-handed circular = 1, RHCP→LHCP = 0, linear→circular = ½.
  struct PolarizationVector: Hashable, Sendable {
    var re: SIMD3<Double>
    var im: SIMD3<Double>

    init(re: SIMD3<Double>, im: SIMD3<Double> = .zero) {
      self.re = re
      self.im = im
    }

    /// Linear polarization along `axis`.
    static func linear(_ axis: SIMD3<Double>) -> PolarizationVector { PolarizationVector(re: axis) }

    var normSquared: Double { simd_length_squared(re) + simd_length_squared(im) }

    /// Unconjugated dot product e₁·e₂ (complex).
    func dot(_ o: PolarizationVector) -> RF.Complex {
      RF.Complex(simd_dot(re, o.re) - simd_dot(im, o.im), simd_dot(re, o.im) + simd_dot(im, o.re))
    }

    /// Rotates the vector by a quaternion.
    func rotated(by q: simd_quatd) -> PolarizationVector {
      PolarizationVector(re: q.act(re), im: q.act(im))
    }

    /// Removes any component along `direction` (keeps the transverse field).
    func transverse(to direction: SIMD3<Double>) -> PolarizationVector {
      let d = simd_normalize(direction)
      return PolarizationVector(re: re - simd_dot(re, d) * d, im: im - simd_dot(im, d) * d)
    }

    /// Polarization loss factor between a wave `self` and a receiving antenna polarization `a`.
    func plf(with a: PolarizationVector) -> Double {
      let n = normSquared * a.normSquared
      guard n > 1e-300 else { return 0 }
      return dot(a).magnitudeSquared / n
    }
  }

  /// Reference polarizations for the Antenna tab's "PLF vs reference" readout and the pose maths.
  enum ReferencePolarization: String, CaseIterable, Codable, Hashable, Sendable {
    case vertical, horizontal, slant45, slantMinus45, rhcp, lhcp

    var displayName: String {
      switch self {
      case .vertical: "V"
      case .horizontal: "H"
      case .slant45: "+45°"
      case .slantMinus45: "−45°"
      case .rhcp: "RHCP"
      case .lhcp: "LHCP"
      }
    }

    /// The transmit polarization of a source radiating along `propagation`, with "vertical"
    /// meaning the component of `up` perpendicular to the ray (falls back to x when the ray is
    /// vertical). Circular uses IEEE handedness: RHCP = (ĥ − j·v̂)/√2 with (ĥ, v̂, d̂) right-handed.
    func vector(propagation: SIMD3<Double>, up: SIMD3<Double> = SIMD3(0, 0, 1)) -> PolarizationVector {
      let d = simd_normalize(propagation)
      var v = up - simd_dot(up, d) * d
      if simd_length(v) < 1e-9 {
        let alt = abs(d.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        v = alt - simd_dot(alt, d) * d
      }
      v = simd_normalize(v)
      let h = simd_cross(v, d)
      let s = 1 / 2.0.squareRoot()
      switch self {
      case .vertical: return .linear(v)
      case .horizontal: return .linear(h)
      case .slant45: return .linear(s * (v + h))
      case .slantMinus45: return .linear(s * (v - h))
      case .rhcp: return PolarizationVector(re: s * h, im: -s * v)
      case .lhcp: return PolarizationVector(re: s * h, im: s * v)
      }
    }
  }
}
