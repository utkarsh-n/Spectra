import CoreMotion
import Foundation

/// Where the Core Motion handlers write: the stream arrays of whichever channels are running
/// (motion: raw accelerometer, raw gyroscope, device motion; magnetometer: raw push and the
/// calibrated device-motion field). nil means "nobody listens".
nonisolated struct MotionTargets: Sendable {
  var accel: [SignalStream]?
  var gyro: [SignalStream]?
  var userAccel: [SignalStream]?
  var gravity: [SignalStream]?
  /// pitch, yaw, roll.
  var attitude: [SignalStream]?
  /// Calibrated x, y, z, |B|.
  var mag: [SignalStream]?
  /// Raw x, y, z, |B|.
  var magRaw: [SignalStream]?
}

/// The newest fused readings, for readouts (not for spectra; those read the rings).
nonisolated struct MotionSnapshot: Sendable {
  /// Attitude quaternion (x, y, z, w), phone → reference frame.
  var quaternion: SIMD4<Double>?
  /// Gravity in the phone frame, g.
  var gravity: SIMD3<Double>?
  /// Calibrated field in the phone frame, µT.
  var field: SIMD3<Double>?
  /// −1 uncalibrated, 0 low, 1 medium, 2 high.
  var fieldAccuracy = -1
  /// Heading relative to the reference frame, degrees (device motion, iOS 11+).
  var heading: Double?
  /// iOS 27 `CMDeviceMotion.headingAccuracy`, degrees (negative when unknown).
  var headingAccuracy: Double?
  /// The attitude reference frame actually used.
  var frame = ""
}

/// The app's one `CMMotionManager` (Apple: one per app), shared by the motion and
/// magnetometer channels. Each Core Motion stream (raw accelerometer, raw gyroscope, raw
/// magnetometer, device motion) runs while at least one channel uses it, at the shortest
/// interval the hardware honours (requested 5 ms; Core Motion caps it), and every sample is
/// pushed with its own `CMLogItem.timestamp` (`gyre-integration.md` §4.3).
@MainActor
final class MotionHardware {
  enum Feature: CaseIterable, Sendable { case accelerometer, gyroscope, magnetometer, deviceMotion }

  let manager = CMMotionManager()
  let targets = Latest(MotionTargets())
  let snapshot = Latest(MotionSnapshot())
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "Spectra.motion"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInitiated
    return q
  }()
  private var users: [Feature: Set<String>] = [:]
  /// High-rate batched accelerometer (`CMBatchedSensorManager`), used instead of the
  /// accelerometer push when this phone supports it (the class is declared for watchOS; the
  /// census reports what iOS answers).
  private var batched: CMBatchedSensorManager?
  /// True while the raw accelerometer comes from the batched manager.
  private(set) var usesBatchedAccelerometer = false

  /// Whether `CMBatchedSensorManager` offers batched accelerometer data here.
  static var batchedAccelerometerSupported: Bool { CMBatchedSensorManager.isAccelerometerSupported }
  static var batchedDeviceMotionSupported: Bool { CMBatchedSensorManager.isDeviceMotionSupported }
  /// Nominal batched accelerometer rate (Hz); the census shows the measured one.
  static let batchedAccelerometerRate = 800.0

  /// The interval requested from Core Motion (200 Hz); the measured rate shows what the
  /// hardware honours.
  static let requestedInterval = 1.0 / 200

  init() {
    manager.showsDeviceMovementDisplay = false
  }

  func isAvailable(_ feature: Feature) -> Bool {
    switch feature {
    case .accelerometer: manager.isAccelerometerAvailable
    case .gyroscope: manager.isGyroAvailable
    case .magnetometer: manager.isMagnetometerAvailable
    case .deviceMotion: manager.isDeviceMotionAvailable
    }
  }

  /// Starts `feature` for `owner` (reference counted).
  func use(_ feature: Feature, by owner: String) {
    var set = users[feature] ?? []
    let wasEmpty = set.isEmpty
    set.insert(owner)
    users[feature] = set
    guard wasEmpty, isAvailable(feature) else { return }
    let targets = targets
    let snapshot = snapshot
    switch feature {
    case .accelerometer:
      if Self.batchedAccelerometerSupported {
        let b = CMBatchedSensorManager()
        b.startAccelerometerUpdates(handler: Self.batchedAccelerometerHandler(targets))
        batched = b
        usesBatchedAccelerometer = true
      } else {
        manager.accelerometerUpdateInterval = Self.requestedInterval
        manager.startAccelerometerUpdates(to: queue, withHandler: Self.accelerometerHandler(targets))
      }
    case .gyroscope:
      manager.gyroUpdateInterval = Self.requestedInterval
      manager.startGyroUpdates(to: queue, withHandler: Self.gyroHandler(targets))
    case .magnetometer:
      manager.magnetometerUpdateInterval = Self.requestedInterval
      manager.startMagnetometerUpdates(to: queue, withHandler: Self.magnetometerHandler(targets))
    case .deviceMotion:
      manager.deviceMotionUpdateInterval = Self.requestedInterval
      let frames = CMMotionManager.availableAttitudeReferenceFrames()
      // Magnetic north when the compass works (azimuths then mean something), otherwise
      // Gyre's magnetometer-corrected arbitrary frame.
      let frame: CMAttitudeReferenceFrame =
        frames.contains(.xMagneticNorthZVertical)
        ? .xMagneticNorthZVertical
        : frames.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical
      snapshot.update { $0.frame = Self.name(of: frame) }
      manager.startDeviceMotionUpdates(using: frame, to: queue, withHandler: Self.deviceMotionHandler(targets, snapshot))
    }
  }

  /// Releases `owner`'s use of `feature`; the Core Motion stream stops when nobody uses it.
  func release(_ feature: Feature, by owner: String) {
    guard var set = users[feature], set.remove(owner) != nil else { return }
    users[feature] = set
    guard set.isEmpty else { return }
    switch feature {
    case .accelerometer:
      if let b = batched {
        b.stopAccelerometerUpdates()
        batched = nil
        usesBatchedAccelerometer = false
      } else {
        manager.stopAccelerometerUpdates()
      }
    case .gyroscope: manager.stopGyroUpdates()
    case .magnetometer: manager.stopMagnetometerUpdates()
    case .deviceMotion:
      manager.stopDeviceMotionUpdates()
      snapshot.set(MotionSnapshot())
    }
  }

  /// If the batched accelerometer delivers nothing (an unexpected authorization or platform
  /// refusal), switch the raw accelerometer back to the push stream.
  func fallBackToPushAccelerometer() {
    guard let b = batched else { return }
    b.stopAccelerometerUpdates()
    batched = nil
    usesBatchedAccelerometer = false
    guard !(users[.accelerometer] ?? []).isEmpty, isAvailable(.accelerometer) else { return }
    manager.accelerometerUpdateInterval = Self.requestedInterval
    manager.startAccelerometerUpdates(to: queue, withHandler: Self.accelerometerHandler(targets))
  }

  func releaseAll(by owner: String) {
    for f in Feature.allCases { release(f, by: owner) }
  }

  private static func name(of frame: CMAttitudeReferenceFrame) -> String {
    switch frame {
    case .xMagneticNorthZVertical: "magnetic north, Z up"
    case .xTrueNorthZVertical: "true north, Z up"
    case .xArbitraryCorrectedZVertical: "arbitrary (corrected), Z up"
    default: "arbitrary, Z up"
    }
  }

  // MARK: Handlers (built off the main actor: they run on the motion queue)

  nonisolated private static func accelerometerHandler(_ targets: Latest<MotionTargets>) -> CMAccelerometerHandler {
    { data, _ in
      guard let data, let s = targets.value.accel, s.count == 3 else { return }
      let t = data.timestamp
      s[0].append(Float(data.acceleration.x), at: t)
      s[1].append(Float(data.acceleration.y), at: t)
      s[2].append(Float(data.acceleration.z), at: t)
    }
  }

  nonisolated private static func batchedAccelerometerHandler(
    _ targets: Latest<MotionTargets>
  ) -> @Sendable ([CMAccelerometerData]?, (any Error)?) -> Void {
    { batch, _ in
      guard let batch, let s = targets.value.accel, s.count == 3 else { return }
      for data in batch {
        let t = data.timestamp
        s[0].append(Float(data.acceleration.x), at: t)
        s[1].append(Float(data.acceleration.y), at: t)
        s[2].append(Float(data.acceleration.z), at: t)
      }
    }
  }

  nonisolated private static func gyroHandler(_ targets: Latest<MotionTargets>) -> CMGyroHandler {
    { data, _ in
      guard let data, let s = targets.value.gyro, s.count == 3 else { return }
      let t = data.timestamp
      s[0].append(Float(data.rotationRate.x), at: t)
      s[1].append(Float(data.rotationRate.y), at: t)
      s[2].append(Float(data.rotationRate.z), at: t)
    }
  }

  nonisolated private static func magnetometerHandler(_ targets: Latest<MotionTargets>) -> CMMagnetometerHandler {
    { data, _ in
      guard let data, let s = targets.value.magRaw, s.count == 4 else { return }
      let t = data.timestamp
      let b = data.magneticField
      s[0].append(Float(b.x), at: t)
      s[1].append(Float(b.y), at: t)
      s[2].append(Float(b.z), at: t)
      s[3].append(Float((b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()), at: t)
    }
  }

  nonisolated private static func deviceMotionHandler(
    _ targets: Latest<MotionTargets>, _ snapshot: Latest<MotionSnapshot>
  ) -> CMDeviceMotionHandler {
    { motion, _ in
      guard let m = motion else { return }
      let t = m.timestamp
      let tg = targets.value
      let g = m.gravity
      let u = m.userAcceleration
      let a = m.attitude
      let field = m.magneticField
      if let s = tg.userAccel, s.count == 3 {
        s[0].append(Float(u.x), at: t)
        s[1].append(Float(u.y), at: t)
        s[2].append(Float(u.z), at: t)
      }
      if let s = tg.gravity, s.count == 3 {
        s[0].append(Float(g.x), at: t)
        s[1].append(Float(g.y), at: t)
        s[2].append(Float(g.z), at: t)
      }
      if let s = tg.attitude, s.count == 3 {
        let deg = 180 / Double.pi
        s[0].append(Float(a.pitch * deg), at: t)
        s[1].append(Float(a.yaw * deg), at: t)
        s[2].append(Float(a.roll * deg), at: t)
      }
      // Before calibration Core Motion may report an all-zero field: skip those samples.
      let b = field.field
      let norm = (b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()
      let calibrated = field.accuracy != .uncalibrated || norm > 1
      if let s = tg.mag, s.count == 4, calibrated {
        s[0].append(Float(b.x), at: t)
        s[1].append(Float(b.y), at: t)
        s[2].append(Float(b.z), at: t)
        s[3].append(Float(norm), at: t)
      }
      let q = a.quaternion
      let accuracy: Int =
        switch field.accuracy {
        case .low: 0
        case .medium: 1
        case .high: 2
        default: -1
        }
      snapshot.update { s in
        s.quaternion = SIMD4(q.x, q.y, q.z, q.w)
        s.gravity = SIMD3(g.x, g.y, g.z)
        s.field = calibrated ? SIMD3(field.field.x, field.field.y, field.field.z) : nil
        s.fieldAccuracy = accuracy
        s.heading = m.heading >= 0 ? m.heading : nil
        s.headingAccuracy = m.headingAccuracy >= 0 ? m.headingAccuracy : nil
      }
    }
  }
}
