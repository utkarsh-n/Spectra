import Foundation
import simd

/// Vector and angle helpers for the spin engine. Namespaced so they never clash with
/// app-wide helpers of the same name (Gyre's `clamped`, `wrapAngle`, `perpendicular`).
nonisolated enum SpinMath {
  static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

  /// Wraps an angle into (−π, π].
  static func wrapAngle(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x <= -.pi { x += 2 * .pi }
    return x
  }

  /// Unit vector, or +Z when the vector is too small to have a direction.
  static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let l = simd_length(v)
    return l > 1e-300 ? v / l : SIMD3(0, 0, 1)
  }

  /// Any unit vector perpendicular to `v`.
  static func perpendicular(to v: SIMD3<Double>) -> SIMD3<Double> {
    let helper = abs(v.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
    return simd_normalize(simd_cross(v, helper))
  }

  /// Rotates `v` right-handedly about the unit vector `axis` by `angle` (Rodrigues).
  /// Uses 2 sin²(θ/2) for 1 − cos θ so tiny angles keep full precision.
  static func rotate(_ v: SIMD3<Double>, about axis: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
    let s = sin(angle)
    let half = sin(0.5 * angle)
    let versine = 2 * half * half
    return v + s * simd_cross(axis, v) + versine * simd_cross(axis, simd_cross(axis, v))
  }

  /// Rotates `v` for `duration` seconds at the angular velocity `w` (rad/s): exact for any step.
  static func rotate(_ v: SIMD3<Double>, angularVelocity w: SIMD3<Double>, duration: Double) -> SIMD3<Double> {
    let rate = simd_length(w)
    guard rate > 0, duration != 0 else { return v }
    return rotate(v, about: w / rate, by: rate * duration)
  }

  /// Rotates `v` about +Z by `angle`.
  static func rotateZ(_ v: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
    let c = cos(angle)
    let s = sin(angle)
    return SIMD3(c * v.x - s * v.y, s * v.x + c * v.y, v.z)
  }
}

/// A seedable SplitMix64 generator: deterministic fades, collisions and fakes (`-seed N`).
nonisolated struct SpinRandom: RandomNumberGenerator, Sendable, Hashable {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in (0, 1]: never exactly zero, so `log` is always finite.
  mutating func uniform() -> Double {
    (Double(next() >> 11) + 1) * 0x1p-53
  }

  /// Standard normal deviate (Box–Muller).
  mutating func gaussian() -> Double {
    let u = uniform()
    let v = uniform()
    return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
  }

  /// Two independent standard normal deviates from one Box–Muller draw.
  mutating func gaussianPair() -> (Double, Double) {
    let r = (-2 * log(uniform())).squareRoot()
    let angle = 2 * .pi * uniform()
    return (r * cos(angle), r * sin(angle))
  }

  /// Unit exponential deviate (the power of a Rayleigh-faded signal).
  mutating func exponential() -> Double { -log(uniform()) }
}

/// A fixed-capacity ring of recent points (Gyre's `TrailBuffer`): the axle-tip trail,
/// the Bloch-tip trail and IQ persistence.
nonisolated struct SpinTrail: Sendable {
  private(set) var points: [SIMD3<Float>]
  private var head = 0
  private(set) var count = 0

  init(capacity: Int) { points = Array(repeating: .zero, count: max(capacity, 1)) }

  var capacity: Int { points.count }

  mutating func append(_ p: SIMD3<Float>) {
    points[head] = p
    head = (head + 1) % points.count
    count = min(count + 1, points.count)
  }

  mutating func clear() { count = 0 }

  /// The stored points, oldest first.
  var ordered: [SIMD3<Float>] {
    let start = (head - count + points.count) % points.count
    return (0..<count).map { points[(start + $0) % points.count] }
  }

  /// Visits the stored points, oldest first.
  func forEach(_ body: (Int, SIMD3<Float>) -> Void) {
    let start = (head - count + points.count) % points.count
    for i in 0..<count { body(i, points[(start + i) % points.count]) }
  }
}
