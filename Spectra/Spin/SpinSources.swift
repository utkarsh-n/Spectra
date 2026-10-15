import Foundation

/// The "Spin FID" source for the Spin tab's Hear it and the Patch node (MODEL · LIVE |B|):
/// a spin species in the live field magnitude, pulsed, ringing down with T₂*.
///
/// Two phase-continuous outputs, each with its own clock so either can be pulled alone:
/// - `renderAudio`: real samples at the synth rate, at the **true** Larmor pitch while it is
///   audible (Earth-field protons ~2.1 kHz) and spectra-lab's mapped pitch otherwise (badge
///   MAPPED). The field is smoothed with τ = 0.25 s so magnetometer noise doesn't warble.
/// - `renderBaseband`: complex I + jQ heterodyned at a reference (the rotating frame), the
///   Patch `iq` port and the Scope's "spin.fid" stream.
///
/// "Your phone measures the field. The spins are simulated." The audio is never a measured FID.
nonisolated struct SpinFIDSource: Sendable {
  var species: SpinSpecies {
    didSet { retune() }
  }
  /// True pitch when audible, or always mapped.
  var pitchPreference: PitchMode = .truePitch {
    didSet { retune() }
  }
  /// Ring-down time (s): T₂*, or the ensemble's dephasing time.
  var t2Star: Double {
    didSet { audio.t2Star = t2Star }
  }
  /// Output level 0…1.
  var level: Double {
    didSet { audio.level = level }
  }
  /// Re-pulse period (s), like an Earth's-field rig repeating its scan; nil = one ring-down
  /// per `pulse()`.
  var repeatInterval: Double? {
    didSet { if !isFollowing { audio.mode = ringMode } }
  }

  /// The audio sample rate (Hz).
  let sampleRate: Double
  /// Smoothed |B₀| (tesla) currently driving the pitch.
  private(set) var field: Double

  private var smoother = FieldSmoother()
  private var audio: FIDOscillator
  private var iqPhase = 0.0
  private var iqSincePulse = Double.infinity
  private var iqPeak = 0.0

  init(
    species: SpinSpecies = .protonWater, field: Double = EarthField.typicalField, sampleRate: Double = 48_000,
    t2Star: Double = 0.5, level: Double = 0.25, repeatInterval: Double? = nil
  ) {
    self.species = species
    self.sampleRate = sampleRate
    self.t2Star = t2Star
    self.level = level
    self.repeatInterval = repeatInterval
    self.field = abs(field)
    let voice = LarmorSonification.voice(species: species, field: abs(field))
    audio = FIDOscillator(
      sampleRate: sampleRate, frequency: voice.audibleHz, t2Star: t2Star,
      mode: repeatInterval.map { .repeating(interval: $0) } ?? .ringDown)
    audio.level = level
    audio.glideTime = 0  // the field itself is smoothed; the pitch follows it exactly
    smoother.update(abs(field), dt: 0)
  }

  // MARK: Readouts

  /// Physical Larmor frequency f_L (Hz) at the smoothed field.
  var larmorHz: Double { species.larmorHz(field: field) }
  /// What the speaker plays and whether it is MAPPED.
  var voice: LarmorVoice { LarmorSonification.voice(species: species, field: field, preferTrue: pitchPreference == .truePitch) }
  /// The Larmor line's free-space wavelength, for the Spectrum strip marker (m).
  var wavelength: Double { species.larmorWavelength(field: field) }
  /// The audio voice's current envelope (0…1).
  var envelope: Double { audio.envelope }

  // MARK: Control

  /// Feeds a live |B| sample (tesla) taken `dt` seconds after the previous one. Non-finite
  /// samples are ignored.
  mutating func updateField(_ magnitude: Double, dt: Double) {
    guard magnitude.isFinite else { return }
    field = smoother.update(abs(magnitude), dt: dt)
    retune()
  }

  /// Sets the field outright (manual B₀ knob), skipping the smoothing. Non-finite values are
  /// ignored.
  mutating func setField(_ magnitude: Double) {
    guard magnitude.isFinite else { return }
    smoother.reset()
    field = smoother.update(abs(magnitude), dt: 0)
    retune()
  }

  /// A π/2 pulse: both outputs restart their ring-down at `amplitude` (and the audio leaves
  /// `follow` mode).
  mutating func pulse(amplitude: Double = 1) {
    audio.mode = ringMode
    audio.trigger(amplitude: amplitude)
    iqSincePulse = 0
    iqPeak = amplitude
  }

  /// Hands the audio envelope to a simulation: call at control rate with the Bloch ensemble's
  /// |M⊥| (0…1), so echoes and Rabi nutation are heard as they happen (`gyre-integration.md`
  /// §4.1 FIDVoice: carrier at audio rate, envelope at control rate). `pulse()` returns to the
  /// analytic ring-down.
  mutating func follow(envelope: Double) {
    audio.mode = .follow
    audio.envelopeTarget = envelope.isFinite ? SpinMath.clamp(envelope, 0, 1) : 0
  }

  /// Whether the audio envelope is following a simulation.
  var isFollowing: Bool {
    if case .follow = audio.mode { return true }
    return false
  }

  private var ringMode: FIDOscillator.EnvelopeMode { repeatInterval.map { .repeating(interval: $0) } ?? .ringDown }

  // MARK: Rendering

  /// `count` audio samples at `sampleRate`.
  mutating func renderAudio(_ count: Int) -> [Float] { audio.render(count) }

  /// Renders into `buffer` without allocating (audio-thread safe once owned by one thread).
  mutating func renderAudio(into buffer: UnsafeMutableBufferPointer<Float>) { audio.render(into: buffer) }

  /// `count` complex baseband samples at `rate`, heterodyned at `referenceHz` (the rotating
  /// frame): a line at s·(f_L − f_ref), s = −1 for clockwise species, under the ring-down, or
  /// under the followed simulation envelope while `isFollowing` (so the Scope and the Patch
  /// `iq` port show the same echo the speaker plays).
  mutating func renderBaseband(count: Int, sampleRate rate: Double, referenceHz: Double) -> [SIMD2<Double>] {
    guard count > 0, rate > 0, rate.isFinite else { return [] }
    let dt = 1 / rate
    let detuning = larmorHz - referenceHz
    let w = detuning.isFinite ? species.precessionSense.sign * 2 * .pi * detuning : 0
    let following = isFollowing
    var out = [SIMD2<Double>]()
    out.reserveCapacity(count)
    for _ in 0..<count {
      if let interval = repeatInterval, interval > 0, iqSincePulse >= interval || !iqSincePulse.isFinite {
        iqSincePulse = 0
        if iqPeak == 0 { iqPeak = 1 }
      }
      var env = 0.0
      if following {
        env = audio.envelopeTarget
      } else if iqSincePulse.isFinite {
        env = iqPeak * (t2Star.isFinite && t2Star > 0 ? exp(-iqSincePulse / t2Star) : 1)
      }
      out.append(SIMD2(env * cos(iqPhase), env * sin(iqPhase)))
      iqPhase = SpinMath.wrapAngle(iqPhase + w * dt)
      iqSincePulse += dt
    }
    return out
  }

  private mutating func retune() { audio.targetFrequency = voice.audibleHz }
}

/// A FIFO of complex samples that hands out fixed-size blocks: the bridge from the heavy
/// top's 960 Hz tip output (drained per frame, a variable count) to the Patch evaluator's
/// fixed blocks. Amortized O(1) per sample.
nonisolated struct IQBlockQueue: Sendable {
  /// Samples beyond this are dropped from the oldest end (a consumer that stopped pulling).
  var capacity: Int
  private var storage: [SIMD2<Double>] = []
  private var head = 0

  init(capacity: Int = 8192) { self.capacity = max(capacity, 1) }

  /// Samples waiting.
  var count: Int { storage.count - head }

  /// The waiting samples, oldest first.
  var samples: ArraySlice<SIMD2<Double>> { storage[head...] }

  mutating func append(contentsOf new: [SIMD2<Double>]) {
    storage.append(contentsOf: new)
    if count > capacity { head += count - capacity }
    compact()
  }

  /// The oldest `size` samples, or nil until that many are queued.
  mutating func popBlock(size: Int) -> [SIMD2<Double>]? {
    guard size > 0, count >= size else { return nil }
    let block = Array(storage[head..<(head + size)])
    head += size
    compact()
    return block
  }

  /// Everything waiting, oldest first.
  mutating func drain() -> [SIMD2<Double>] {
    let out = Array(samples)
    removeAll()
    return out
  }

  mutating func removeAll() {
    storage.removeAll(keepingCapacity: true)
    head = 0
  }

  /// Drops consumed samples once they outnumber the live ones.
  private mutating func compact() {
    if head > 0, head >= storage.count - head {
      storage.removeFirst(head)
      head = 0
    }
  }
}
