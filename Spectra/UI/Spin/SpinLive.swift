import Foundation
import simd

/// One frame of the phone's motion and field as the Spin tab uses them, all rotated into the
/// world frame of Core Motion's attitude (z up; x/y follow the attitude's reference frame).
/// Built from the stream bus, so it works the same with real sensors and with the SIM fakes.
nonisolated struct SpinLiveSample: Sendable {
  /// Device → world rotation from the attitude (or from gravity alone when no attitude
  /// stream exists).
  var attitude: simd_double3x3?
  /// Gravity in the phone frame (g), pointing down.
  var gravityDevice: SIMD3<Double>?
  /// Phone rotation rate in world axes (rad/s).
  var rateWorld: SIMD3<Double>?
  /// Phone acceleration minus gravity in world axes (m/s²).
  var linearWorld: SIMD3<Double>?
  /// The magnetic field in the phone frame (µT), averaged over ~0.1 s.
  var fieldDevice: SIMD3<Double>?
  /// The magnetic field in world axes (tesla), averaged over ~0.1 s.
  var fieldWorld: SIMD3<Double>?
  /// The newest |B| sample (tesla).
  var fieldMagnitude: Double?
  /// Air pressure (Pa), when a barometer stream is running.
  var pressure: Double?

  var hasMotion: Bool { attitude != nil && rateWorld != nil }
  var hasField: Bool { fieldWorld != nil && fieldMagnitude != nil }
}

/// Reads `SpinLiveSample`s from the stream registry (`Docs/API.md` §5 ids). Prefers the live
/// builder's richer streams (`gravity.*`, `accel.user.*`) and falls back to the stage-1 set
/// (`accel.*`, `gyro.*`, `attitude.*`, `mag.*`).
///
/// Called every frame, so it keeps the hot path cheap: the streams are looked up twice a second
/// (a restarted sensor registers new instances under the same ids), the newest samples are read
/// without allocating, and the 0.1 s means (raw accelerometer, magnetometer vector) are
/// refreshed at 20 Hz.
struct SpinLiveReader {
  /// Standard gravity (m/s² per g), from the engine's constants.
  static let g0 = SpinConstants.standardGravity

  private struct Triple {
    let x: SignalStream
    let y: SignalStream
    let z: SignalStream
  }

  private var resolvedAt = -Double.infinity
  private var averagedAt = -Double.infinity
  private var gravity: Triple?
  private var accel: Triple?
  private var attitude: Triple?
  private var gyro: Triple?
  private var user: Triple?
  private var mag: Triple?
  private var norm: SignalStream?
  private var pressure: SignalStream?
  private var meanAccel: SIMD3<Double>?
  private var meanMag: SIMD3<Double>?

  /// The phone's motion and field now (`now` is `SignalClock.now()`).
  mutating func read(_ registry: StreamRegistry, now: Double) -> SpinLiveSample {
    if now - resolvedAt > 0.5 || now < resolvedAt {
      resolve(registry)
      resolvedAt = now
      averagedAt = -.infinity
    }
    if now - averagedAt >= 0.05 || now < averagedAt {
      averagedAt = now
      meanAccel = accel.flatMap { Self.mean($0, last: 10) }
      meanMag = mag.flatMap { Self.mean($0, last: 10) }
    }
    var s = SpinLiveSample()
    // Gravity in the phone frame: the device-motion stream, else a 0.1 s mean of the raw
    // accelerometer (the static part of it is gravity).
    let g = gravity.flatMap(Self.latest) ?? meanAccel
    s.gravityDevice = g
    if let angles = attitude.flatMap(Self.latest) {
      s.attitude = Self.rotation(pitch: angles.x * .pi / 180, yaw: angles.y * .pi / 180, roll: angles.z * .pi / 180)
    } else if let g {
      s.attitude = Self.rotation(gravity: g)
    }
    if let r = s.attitude {
      if let w = gyro.flatMap(Self.latest) { s.rateWorld = r * w }
      if let u = user.flatMap(Self.latest) {
        s.linearWorld = r * u * Self.g0
      } else if let raw = accel.flatMap(Self.latest), let g {
        s.linearWorld = r * (raw - g) * Self.g0
      }
      if let b = meanMag {
        s.fieldDevice = b
        s.fieldWorld = r * b * 1e-6
      }
    } else if let b = meanMag {
      s.fieldDevice = b
      s.fieldWorld = b * 1e-6
    }
    if let norm {
      if let latest = norm.ring.latest, latest.value.isFinite { s.fieldMagnitude = Double(latest.value) * 1e-6 }
    } else if let b = s.fieldWorld {
      s.fieldMagnitude = simd_length(b)
    }
    if let p = pressure?.ring.latest, p.value.isFinite, p.value > 0 {
      s.pressure = Double(p.value)
    }
    return s
  }

  private mutating func resolve(_ registry: StreamRegistry) {
    func triple(_ x: String, _ y: String, _ z: String) -> Triple? {
      guard let sx = registry.stream(StreamID(x)), let sy = registry.stream(StreamID(y)),
        let sz = registry.stream(StreamID(z))
      else { return nil }
      return Triple(x: sx, y: sy, z: sz)
    }
    gravity = triple("gravity.x", "gravity.y", "gravity.z")
    accel = triple("accel.x", "accel.y", "accel.z")
    attitude = triple("attitude.pitch", "attitude.yaw", "attitude.roll")
    gyro = triple("gyro.x", "gyro.y", "gyro.z")
    user = triple("accel.user.x", "accel.user.y", "accel.user.z")
    mag = triple("mag.x", "mag.y", "mag.z")
    norm = registry.stream("mag.norm")
    pressure = registry.stream("baro.pressure")
  }

  /// The newest sample of each axis (no allocation), or nil if any is missing or not finite.
  private static func latest(_ t: Triple) -> SIMD3<Double>? {
    guard let a = t.x.ring.latest?.value, let b = t.y.ring.latest?.value, let c = t.z.ring.latest?.value,
      a.isFinite, b.isFinite, c.isFinite
    else { return nil }
    return SIMD3(Double(a), Double(b), Double(c))
  }

  /// The mean of the newest `last` samples of each axis, or nil if any is missing.
  private static func mean(_ t: Triple, last: Int) -> SIMD3<Double>? {
    func axis(_ s: SignalStream) -> Double? {
      let snap = s.ring.snapshot(last: last)
      guard !snap.isEmpty else { return nil }
      return snap.values.reduce(0) { $0 + Double($1) } / Double(snap.count)
    }
    guard let a = axis(t.x), let b = axis(t.y), let c = axis(t.z), a.isFinite, b.isFinite, c.isFinite else { return nil }
    return SIMD3(a, b, c)
  }

  /// RMS scatter of |B| over the last second (tesla), or nil without enough samples. Called at
  /// the readout rate, not per frame.
  static func fieldNoise(_ registry: StreamRegistry) -> Double? {
    guard let norm = registry.stream("mag.norm") else { return nil }
    let window = norm.ring.snapshot(since: SignalClock.now() - 1)
    guard window.count > 8 else { return nil }
    let values = window.values.map(Double.init)
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
    return variance.squareRoot() * 1e-6
  }

  /// Core Motion's Euler convention: device → reference = R_z(yaw) · R_x(pitch) · R_y(roll).
  static func rotation(pitch p: Double, yaw y: Double, roll r: Double) -> simd_double3x3 {
    let rz = simd_double3x3(rows: [SIMD3(cos(y), -sin(y), 0), SIMD3(sin(y), cos(y), 0), SIMD3(0, 0, 1)])
    let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
    let ry = simd_double3x3(rows: [SIMD3(cos(r), 0, sin(r)), SIMD3(0, 1, 0), SIMD3(-sin(r), 0, cos(r))])
    return rz * rx * ry
  }

  /// A device → world rotation from gravity alone (yaw arbitrary): world z is "up".
  static func rotation(gravity g: SIMD3<Double>) -> simd_double3x3? {
    let len = simd_length(g)
    guard len > 0.1, len.isFinite else { return nil }
    let up = -g / len
    var east = simd_cross(SIMD3(0, 1, 0), up)
    if simd_length(east) < 1e-3 { east = simd_cross(SIMD3(1, 0, 0), up) }
    east = simd_normalize(east)
    let north = simd_cross(up, east)
    // Rows are the world axes expressed in the device frame.
    return simd_double3x3(rows: [east, north, up])
  }
}

/// Core Motion's magnetometer calibration accuracy (−1 uncalibrated, 0 low, 1 medium, 2 high),
/// which `gyre-integration.md` §4.1 asks to show next to f_L (1 µT of bias moves the proton
/// line by 42.6 Hz). The live slice's `MagnetometerChannel` has `accuracy`; it reports it here
/// through this protocol once integration adds the one-line conformance
/// (`extension MagnetometerChannel: SpinCalibrationReporting {}`), and until then the value is
/// read by reflection. Nil when the channel exposes neither (the stage-1 simulated channel).
@MainActor
protocol SpinCalibrationReporting: AnyObject {
  var accuracy: Int { get }
}

@MainActor
enum SpinMagnetometerCalibration {
  /// The channel's accuracy, or nil when it does not report one.
  static func accuracy(of channel: any SensorChannel) -> Int? {
    if let reporting = channel as? SpinCalibrationReporting { return reporting.accuracy }
    // @Observable keeps a stored `accuracy` as `_accuracy`.
    for child in Mirror(reflecting: channel).children where child.label == "_accuracy" || child.label == "accuracy" {
      if let value = child.value as? Int, (-1...2).contains(value) { return value }
    }
    return nil
  }

  /// "high", "medium", "low", "uncalibrated".
  static func title(_ accuracy: Int) -> String {
    switch accuracy {
    case 2: "high"
    case 1: "medium"
    case 0: "low"
    default: "uncalibrated"
    }
  }
}
