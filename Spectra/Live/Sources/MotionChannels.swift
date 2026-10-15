import CoreMotion
import Foundation
import Observation

/// Motion: raw accelerometer and gyroscope (timestamped push at the highest rate Core Motion
/// honours, or the batched accelerometer where iOS offers it), plus device motion's user
/// acceleration, gravity and attitude. No permission prompt.
@Observable @MainActor
final class MotionChannel: LiveSource {
  let core: ChannelCore
  /// Angle between the screen and the horizontal (0° lying flat), from gravity.
  private(set) var tilt: Double?
  /// Pitch and roll (degrees) from the attitude.
  private(set) var pitch: Double?
  private(set) var roll: Double?
  /// Yaw (degrees) from the attitude, for the turntable experiment.
  private(set) var yaw: Double?
  /// RMS of the user acceleration over the last second (g).
  private(set) var vibrationRMS: Double?
  @ObservationIgnored private var startedAt = 0.0

  private static let owner = "motion"

  init(context: LiveContext) {
    core = ChannelCore(id: .motion, context: context)
    // The badge before the first run says what it will be.
    core.provenance = context.simulates(.motion, hardwareAvailable: context.motion.isAvailable(.deviceMotion)) ? .sim : .live
  }

  private var hardware: MotionHardware { core.context.motion }

  var markers: [SpectrumMarker] { [] }

  var startsSilently: Bool { true }

  func start() async {
    guard core.state != .running else { return }
    let hw = hardware
    let available = hw.isAvailable(.deviceMotion) || hw.isAvailable(.accelerometer)
    let sim = core.context.simulates(.motion, hardwareAvailable: available)
    guard sim || available else {
      core.state = .unavailable("This device reports no accelerometer or gyroscope.")
      return
    }
    core.prepare(simulated: sim)
    // The batched accelerometer delivers 800 Hz: size the raw rings for 30 s of that.
    let batched = !sim && hw.isAvailable(.accelerometer) && MotionHardware.batchedAccelerometerSupported
    let accel = core.make(LiveStreams.accel, rate: batched ? MotionHardware.batchedAccelerometerRate : nil)
    let user = core.make(LiveStreams.userAccel)
    let gravity = core.make(LiveStreams.gravity)
    let gyro = core.make(LiveStreams.gyro)
    let attitude = core.make(LiveStreams.attitude)
    core.publish(accel + user + gravity + gyro + attitude)
    let t0 = SignalClock.now()
    if sim {
      let seed = core.context.seed(for: .motion)
      core.runSimulation(
        MotionGenerator(
          accel: accel, userAccel: user, gravity: gravity, gyro: gyro, attitude: attitude, pose: core.context.pose,
          grid: SampleGrid(rate: 100, jitter: 0.01, start: t0, seed: seed), rng: SimRandom(seed: seed)))
    } else {
      hw.targets.update {
        $0.accel = accel
        $0.gyro = gyro
        $0.userAccel = user
        $0.gravity = gravity
        $0.attitude = attitude
      }
      hw.use(.accelerometer, by: Self.owner)
      hw.use(.gyroscope, by: Self.owner)
      hw.use(.deviceMotion, by: Self.owner)
    }
    startedAt = t0
    core.state = .running
    refresh()
  }

  func stop() {
    if core.state == .running, !core.simulated {
      hardware.targets.update {
        $0.accel = nil
        $0.gyro = nil
        $0.userAccel = nil
        $0.gravity = nil
        $0.attitude = nil
      }
      hardware.releaseAll(by: Self.owner)
    }
    tilt = nil
    pitch = nil
    roll = nil
    yaw = nil
    vibrationRMS = nil
    core.reset()
  }

  func refresh() {
    guard core.state == .running else { return }
    core.refreshRate(from: LiveStreams.accel[0])
    // An iOS that claims batched accelerometer support but sends nothing falls back to push.
    if !core.simulated, hardware.usesBatchedAccelerometer, SignalClock.now() - startedAt > 1.5,
      core.stream(LiveStreams.accel[0].id)?.ring.count == 0
    {
      hardware.fallBackToPushAccelerometer()
    }
    if let gz = core.latest(LiveStreams.gravity[2]) {
      tilt = acos(min(1, abs(gz))) * 180 / .pi
    }
    pitch = core.latest(LiveStreams.attitude[0])
    yaw = core.latest(LiveStreams.attitude[1])
    roll = core.latest(LiveStreams.attitude[2])
    let now = SignalClock.now()
    var sum = 0.0
    var n = 0
    for spec in LiveStreams.userAccel {
      guard let s = core.stream(spec.id) else { continue }
      let snap = s.ring.snapshot(since: now - 1)
      for v in snap.values {
        sum += Double(v) * Double(v)
        n += 1
      }
    }
    // |a_user| rms: three axis samples per instant.
    vibrationRMS = n > 0 ? (3 * sum / Double(n)).squareRoot() : nil
    if let tilt {
      core.primaryReadout = "tilt \(Int(tilt.rounded()))° · " + (vibrationRMS.map { "\(SpectraFormat.significant($0 * 1000, 2)) mg rms" } ?? "—")
    }
  }

  var capabilities: [CapabilityFlag] {
    let m = hardware.manager
    return [
      CapabilityFlag("Accelerometer", m.isAccelerometerAvailable, source: "CMMotionManager.isAccelerometerAvailable"),
      CapabilityFlag("Gyroscope", m.isGyroAvailable, source: "CMMotionManager.isGyroAvailable"),
      CapabilityFlag("Device motion", m.isDeviceMotionAvailable, source: "CMMotionManager.isDeviceMotionAvailable"),
      CapabilityFlag(
        "Batched accelerometer", MotionHardware.batchedAccelerometerSupported,
        source: "CMBatchedSensorManager.isAccelerometerSupported"),
      CapabilityFlag(
        "Batched device motion", MotionHardware.batchedDeviceMotionSupported,
        source: "CMBatchedSensorManager.isDeviceMotionSupported"),
      CapabilityFlag(
        "Accelerometer rate", rateValue(LiveStreams.accel[0]), source: "CMLogItem.timestamp, requested 200 Hz"),
      CapabilityFlag("Gyroscope rate", rateValue(LiveStreams.gyro[0]), source: "CMLogItem.timestamp, requested 200 Hz"),
      CapabilityFlag(
        "Device motion rate", rateValue(LiveStreams.attitude[0]), source: "CMLogItem.timestamp, requested 200 Hz"),
      CapabilityFlag(
        "Attitude frame", hardware.snapshot.value.frame.isEmpty ? .unknown : .text(hardware.snapshot.value.frame),
        source: "availableAttitudeReferenceFrames"),
    ]
  }

  private func rateValue(_ spec: LiveStreamSpec) -> CapabilityFlag.Value {
    guard let r = core.stream(spec.id)?.measuredRate else { return .unknown }
    return .text(SpectraFormat.rate(r) + (core.simulated ? " (SIM)" : ""))
  }
}

/// The magnetometer as an ELF probe (`gyre-integration.md` §4.3): the raw field pushed at the
/// hardware's top rate with its own timestamps (the FFT input, bias included, which does not
/// matter for AC), and the calibrated device-motion field for the DC vector and |B|. A spectrum
/// of the raw axes, refreshed with the readouts, finds mains hum folded by sampling.
@Observable @MainActor
final class MagnetometerChannel: LiveSource {
  let core: ChannelCore
  /// Calibrated field (µT, phone frame), falling back to raw before calibration.
  private(set) var field: SIMD3<Double>?
  /// Gravity in the phone frame (g), for the dip angle.
  private(set) var gravity: SIMD3<Double>?
  /// Whether `field` is the calibrated (bias-free) one.
  private(set) var isCalibrated = false
  /// Core Motion's calibration accuracy: −1 uncalibrated … 2 high.
  private(set) var accuracy = -1
  /// Spectrum of the raw axes (AC power summed over x, y, z).
  private(set) var spectrum: LiveAnalysis.Spectrum?
  /// Mains frequency whose alias stands out of the spectrum (nil = none).
  private(set) var detectedMains: Double?
  /// FFT length of the spectrum (256, 512 or 1024 samples).
  var fftCount = 512 {
    didSet { if ![256, 512, 1024].contains(fftCount) { fftCount = 512 } }
  }

  private static let owner = "magnetometer"

  init(context: LiveContext) {
    core = ChannelCore(id: .magnetometer, context: context)
    core.provenance = context.simulates(.magnetometer, hardwareAvailable: context.motion.isAvailable(.magnetometer)) ? .sim : .live
  }

  private var hardware: MotionHardware { core.context.motion }
  private var fake: LaunchOptions.MagnetometerFake? { core.simulated ? (core.context.launch.fakeMag ?? .earth) : nil }

  var startsSilently: Bool { true }

  func start() async {
    guard core.state != .running else { return }
    let hw = hardware
    let available = hw.isAvailable(.magnetometer)
    let sim = core.context.simulates(.magnetometer, hardwareAvailable: available)
    guard sim || available else {
      core.state = .unavailable("This device reports no magnetometer.")
      return
    }
    core.prepare(simulated: sim)
    let mode = core.context.launch.fakeMag ?? .earth
    let hum = sim && (mode == .hum60 || mode == .hum50)
    // The hum fakes sample at 99.8 Hz ± 2 % (gyre-integration §8), so 60 Hz folds to 39.8 Hz.
    let rate: Double? = hum ? 99.8 : nil
    let calibrated = (LiveStreams.mag + [LiveStreams.magNorm]).map { core.make($0, rate: rate) }
    let raw = (LiveStreams.magRaw + [LiveStreams.magRawNorm]).map { core.make($0, rate: rate) }
    core.publish(calibrated + raw)
    if sim {
      let t0 = SignalClock.now()
      let seed = core.context.seed(for: .magnetometer)
      core.runSimulation(
        MagnetometerGenerator(
          calibrated: calibrated, raw: raw, mode: mode, pose: core.context.pose, t0: t0,
          grid: SampleGrid(rate: hum ? 99.8 : 100, jitter: hum ? 0.02 : 0.01, start: t0, seed: seed),
          rng: SimRandom(seed: seed)))
    } else {
      hw.targets.update {
        $0.mag = calibrated
        $0.magRaw = raw
      }
      hw.use(.magnetometer, by: Self.owner)
      hw.use(.deviceMotion, by: Self.owner)
    }
    core.state = .running
    refresh()
  }

  func stop() {
    if core.state == .running, !core.simulated {
      hardware.targets.update {
        $0.mag = nil
        $0.magRaw = nil
      }
      hardware.releaseAll(by: Self.owner)
    }
    field = nil
    gravity = nil
    spectrum = nil
    detectedMains = nil
    accuracy = -1
    isCalibrated = false
    core.reset()
  }

  func refresh() {
    guard core.state == .running else { return }
    core.refreshRate(from: LiveStreams.magRaw[0])
    let cal = LiveStreams.mag.compactMap { core.latest($0) }
    let raw = LiveStreams.magRaw.compactMap { core.latest($0) }
    if cal.count == 3 {
      field = SIMD3(cal[0], cal[1], cal[2])
      isCalibrated = true
    } else if raw.count == 3 {
      field = SIMD3(raw[0], raw[1], raw[2])
      isCalibrated = false
    }
    if core.simulated {
      gravity = core.context.pose.toPhone(SIMD3(0, 0, -1), at: SignalClock.now())
      accuracy = 2
    } else {
      let snap = hardware.snapshot.value
      gravity = snap.gravity
      accuracy = snap.fieldAccuracy
    }
    if let b = field {
      core.primaryReadout = "|B| \(SpectraFormat.significant((b * b).sum().squareRoot(), 3)) µT"
    }
    updateSpectrum()
  }

  /// Recomputes the raw-axis spectrum at the measured rate.
  func updateSpectrum() {
    guard let fs = core.measuredRate, fs > 4 else { return }
    let span = Double(fftCount) / fs + 0.5
    let now = SignalClock.now()
    let axes = LiveStreams.magRaw.compactMap { core.stream($0.id)?.ring.snapshot(since: now - span) }
    guard axes.count == 3 else { return }
    // Above 2 Hz: turning the phone in Earth's field fills the lowest bins.
    spectrum = LiveAnalysis.spectrum(axes: axes, rate: fs, count: fftCount, peakAbove: 2)
    detectedMains = spectrum.flatMap { LiveAnalysis.detectMains(in: $0) }
  }

  /// The Earth-field geometry (Spin engine): |B|, dip angle and magnetic latitude.
  var earthField: EarthField? {
    guard let field, let gravity, (gravity * gravity).sum() > 0.01 else { return nil }
    return EarthField(microtesla: field, gravity: gravity)
  }

  var markers: [SpectrumMarker] {
    let simMains: Double? =
      switch fake {
      case .hum60: 60
      case .hum50: 50
      default: nil
      }
    guard let mains = simMains ?? detectedMains else { return [] }
    let fs = core.measuredRate ?? 99.8
    let alias = RF.DSP.aliasFrequency(mains, sampleRate: fs)
    return [
      SpectrumMarker(
        id: "live.mains", label: "Mains hum \(Int(mains)) Hz (seen at \(SpectraFormat.significant(alias, 3)) Hz)",
        // The alias line is measured; that it is the mains (and which mains) is inferred.
        frequency: mains, provenance: core.simulated ? .sim : .inferred, tab: .live)
    ]
  }

  var capabilities: [CapabilityFlag] {
    let rate = core.stream(LiveStreams.magRaw[0].id)?.measuredRate
    var flags = [
      CapabilityFlag("Magnetometer", hardware.manager.isMagnetometerAvailable, source: "CMMotionManager.isMagnetometerAvailable"),
      CapabilityFlag(
        "Raw push rate", rate.map { .text(SpectraFormat.rate($0) + (core.simulated ? " (SIM)" : "")) } ?? .unknown,
        source: "CMLogItem.timestamp, requested 200 Hz"),
      CapabilityFlag(
        "Calibration", accuracy < 0 ? .unknown : .text(["low", "medium", "high"][min(2, accuracy)] + (core.simulated ? " (SIM)" : "")),
        source: "CMCalibratedMagneticField.accuracy"),
    ]
    if let x = core.stream(LiveStreams.magRaw[0].id)?.ring.snapshot(last: 200), x.count > 20 {
      flags.append(
        CapabilityFlag(
          "Timestamp jitter", .text("±\(SpectraFormat.significant(LiveAnalysis.intervalJitter(x.times) * 100, 2)) %"),
          source: "σ of sample intervals; above 1 % the FFT resamples"))
    }
    if let s = spectrum {
      flags.append(
        CapabilityFlag(
          "Mains line", detectedMains.map { .text("\(Int($0)) Hz seen at \(SpectraFormat.significant(RF.DSP.aliasFrequency($0, sampleRate: s.sampleRate), 3)) Hz") } ?? .text("none above the floor"),
          source: "FFT of the raw axes"))
    }
    return flags
  }
}
