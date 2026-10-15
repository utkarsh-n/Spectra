import Foundation
import simd

/// The gyroscope as the Spin tab and the Patch "Gyroscope tip" node use it (MODEL · LIVE
/// motion): one `HeavyTop` with its knobs, an optional rotating-field drive for classical
/// magnetic resonance, the axle-tip IQ stream and the axle trail. Gyre's `GyroEngine`
/// without the UI (`gyre-integration.md` §3, §4.8).
///
/// Time: `advance(dtReal:)` takes wall seconds; the rotor runs D = `params.timeScale` simulated
/// seconds per wall second. The tip stream is sampled at 960 Hz of *simulated* time, so its
/// wall-clock rate is 960·D (`wallClockTipRate`): declare that on the Patch `iq` port.
///
/// A plain value: owned by one `@MainActor` model (the Spin tab's) and stepped from its render
/// loop; Patch reads blocks from the same instance.
nonisolated struct GyroscopeEngine: Sendable {
  /// The knobs.
  var params: HeavyTopParams
  /// When set, the rotor feels B₀ẑ + rotating B₁ (the "Magnetic resonance with a gyroscope"
  /// trip) instead of the environment's field.
  var resonance: RotorResonanceDrive?

  private(set) var top = HeavyTop()
  /// Recent axle-tip positions (world axes, unit sphere), one per `advance`: the trail.
  private(set) var trail: SpinTrail
  /// The field the rotor felt in the last step (tesla, world axes).
  private(set) var appliedField = SIMD3<Double>.zero
  private var tipQueue: IQBlockQueue

  /// - Parameters:
  ///   - trailCapacity: trail points kept (720 = 6 s at 120 fps).
  ///   - tipCapacity: tip samples kept when nobody pulls (8192 ≈ 8.5 simulated seconds).
  init(params: HeavyTopParams = HeavyTopParams(), tilt: Double = 0.32, trailCapacity: Int = 720, tipCapacity: Int = 8192) {
    self.params = params
    trail = SpinTrail(capacity: trailCapacity)
    tipQueue = IQBlockQueue(capacity: tipCapacity)
    launch(tilt: tilt)
  }

  // MARK: Readouts

  /// The 10 Hz snapshot for chips, haptics and Patch control outputs.
  var telemetry: HeavyTopTelemetry { top.telemetry }
  /// The axle-tip sample rate per simulated second (960 Hz).
  var tipSampleRate: Double { HeavyTop.tipSampleRate }
  /// The tip stream's rate on the wall clock, 960·D (Hz).
  var wallClockTipRate: Double { HeavyTop.tipSampleRate * max(params.sanitized.timeScale, 0.02) }
  /// Tip samples waiting to be pulled.
  var pendingTipCount: Int { tipQueue.count }
  /// The axle tip eₓ + ie_y right now.
  var tip: SIMD2<Double> { top.tip }
  /// The rotor's mechanical gyromagnetic ratio μ/L₃ at the current spin (rad s⁻¹ T⁻¹).
  var rotorGamma: Double { top.rotorGamma(magnet: params.magnet) }

  // MARK: Control

  /// Restarts the rotor at `tilt` in steady precession (Gyre's `launch`) and clears the
  /// trail and the tip stream.
  mutating func launch(tilt: Double = 0.32, azimuth: Double = 0.6, rpm: Double? = nil) {
    top.launch(params: params, tilt: tilt, azimuth: azimuth, rpm: rpm)
    trail.clear()
    tipQueue.removeAll()
    appliedField = .zero
    if let drive = resonance {
      resonance = RotorResonanceDrive.resonant(with: top, magnet: params.magnet, b0: drive.b0, b1: drive.b1, phase: drive.phase)
    }
  }

  /// Loads a preset: its knobs, its launch tilt and, for the resonance trip, a co-rotating
  /// B₁ on resonance (50 µT, 10 µT: the axis tips 90° in 11.1 s).
  mutating func apply(_ preset: HeavyTopPreset) {
    params = preset.params
    resonance = preset.resonance ? RotorResonanceDrive(omega: 0) : nil
    launch(tilt: preset.tilt)
  }

  /// Retunes the resonance drive to the rotor's current Larmor rate (after a Motor or
  /// Magnet change), keeping B₀, B₁ and phase.
  mutating func retuneResonance() {
    guard let drive = resonance else { return }
    resonance = RotorResonanceDrive.resonant(with: top, magnet: params.magnet, b0: drive.b0, b1: drive.b1, phase: drive.phase)
  }

  /// Advances `dtReal` wall seconds in `environment` (live gravity via `linearAccel`, device
  /// rate, field, pressure). Tip samples go to the queue; the axle tip goes to the trail.
  mutating func advance(dtReal: Double, environment: HeavyTopEnvironment) {
    var env = environment
    if let drive = resonance { env.magneticField = drive.field(at: top.time) }
    appliedField = env.magneticField
    top.step(dtReal: dtReal, env: env, params: params)
    let fresh = top.drainTip()
    if !fresh.isEmpty { tipQueue.append(contentsOf: fresh) }
    if dtReal > 0, !top.paused { trail.append(SIMD3<Float>(top.axis)) }
  }

  /// Pauses or resumes the rotor (simulated time and the tip stream stand still).
  mutating func setPaused(_ paused: Bool) { top.paused = paused }

  /// Knocks the axis sideways (Gyre's tap): `strength` 0…1 of the |L|-scaled impulse.
  mutating func kick(strength: Double, angle: Double) { top.kick(strength: strength, angle: angle) }

  /// Adds angular momentum along the axis (a string pull), J·s.
  mutating func addSpin(_ dL3: Double) { top.addSpin(dL3) }

  // MARK: Tip stream

  /// The oldest `size` tip samples, or nil until that many are waiting (Patch blocks).
  mutating func popTipBlock(size: Int) -> [SIMD2<Double>]? { tipQueue.popBlock(size: size) }

  /// Every waiting tip sample, oldest first (Scope ring writers).
  mutating func drainTip() -> [SIMD2<Double>] { tipQueue.drain() }
}
