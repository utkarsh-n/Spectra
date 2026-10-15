import Foundation
import simd

/// The detected FID as the Spin tab keeps it: a rolling window for the trace, and the most
/// recent complete record (from a sequence start) for the spectrum and the Wigner view.
/// Samples are complex baseband (mean Mₓ + iM_y in the rotating frame) at `sampleRate`
/// species hertz.
nonisolated struct SpinRecorder: Sendable {
  /// Samples per species second.
  let sampleRate: Double
  /// Samples in the rolling window and in one record.
  let capacity: Int
  /// The rolling window, oldest first once full (`head` marks the oldest).
  private(set) var window: [SIMD2<Double>]
  private(set) var windowMz: [Double]
  private var head = 0
  private(set) var windowCount = 0
  /// Samples since the last sequence start (or the last roll-over).
  private(set) var current: [SIMD2<Double>] = []
  private var currentTriggered = false
  private var samplesSinceTrigger = Int.max / 2
  /// The latest complete record, and a counter that changes whenever it does.
  private(set) var record: [SIMD2<Double>] = []
  private(set) var recordTriggered = false
  private(set) var revision = 0
  /// The latest complete record that started at a pulse, kept for the triggered trace until the
  /// next one (an untriggered CW record does not replace it).
  private(set) var held: [SIMD2<Double>] = []

  init(sampleRate: Double, seconds: Double) {
    self.sampleRate = sampleRate
    capacity = max(64, Int((sampleRate * seconds).rounded()))
    window = Array(repeating: .zero, count: capacity)
    windowMz = Array(repeating: 1, count: capacity)
    current.reserveCapacity(capacity)
  }

  /// Adds one sample (signal and the mean M_z). `rolling` (CW drive) lets untriggered records
  /// replace the last one; otherwise only a pulse's record does, so the spectrum and Wigner view
  /// keep the last FID instead of the dephased tail before the next repeat.
  mutating func append(_ s: SIMD2<Double>, mz: Double, rolling: Bool = false) {
    window[head] = s
    windowMz[head] = mz
    head = (head + 1) % capacity
    windowCount = min(windowCount + 1, capacity)
    current.append(s)
    samplesSinceTrigger &+= 1
    if current.count >= capacity {
      // A full record. A triggered one (from a pulse) always replaces the last record; an
      // untriggered one only under CW drive once no pulse has played for two windows.
      if currentTriggered || (rolling && samplesSinceTrigger > 2 * capacity) { publish(triggered: currentTriggered) }
      current.removeAll(keepingCapacity: true)
      currentTriggered = false
    }
  }

  /// A sequence starts now: the partial record (if long enough) becomes the last record and a
  /// new triggered one begins.
  mutating func trigger() {
    if currentTriggered, current.count >= 32 { publish(triggered: true) }
    current.removeAll(keepingCapacity: true)
    currentTriggered = true
    samplesSinceTrigger = 0
  }

  mutating func clear() {
    head = 0
    windowCount = 0
    current.removeAll(keepingCapacity: true)
    currentTriggered = false
    record = []
    held = []
    revision &+= 1
  }

  private mutating func publish(triggered: Bool) {
    record = current
    recordTriggered = triggered
    if triggered { held = current }
    revision &+= 1
  }

  /// What a triggered trace shows, like a scope in Normal mode: the sweep since the last pulse
  /// while it fills, then the last pulse's record held; nil before any pulse (show the rolling
  /// window). `filled` is the fraction of one record the samples cover.
  func triggeredSweep(maxPoints: Int = 600) -> (signal: [SIMD2<Double>], filled: Double)? {
    let source = currentTriggered && !current.isEmpty ? current : held
    guard source.count > 1 else { return nil }
    let stride = max(1, Int((Double(source.count) / Double(max(maxPoints, 16))).rounded(.up)))
    var s: [SIMD2<Double>] = []
    s.reserveCapacity(source.count / stride + 1)
    var i = 0
    while i < source.count {
      s.append(source[i])
      i += stride
    }
    if let last = source.last, (source.count - 1) % stride != 0 { s.append(last) }
    return (s, min(1, Double(source.count) / Double(capacity)))
  }

  /// The rolling window, oldest first, decimated to at most `maxPoints` samples.
  func orderedWindow(maxPoints: Int = 600) -> (signal: [SIMD2<Double>], mz: [Double]) {
    let n = windowCount
    guard n > 0 else { return ([], []) }
    let start = (head - n + capacity) % capacity
    let stride = max(1, Int((Double(n) / Double(max(maxPoints, 16))).rounded(.up)))
    var s: [SIMD2<Double>] = []
    var z: [Double] = []
    s.reserveCapacity(n / stride + 1)
    z.reserveCapacity(n / stride + 1)
    var i = 0
    while i < n {
      let k = (start + i) % capacity
      s.append(window[k])
      z.append(windowMz[k])
      i += stride
    }
    return (s, z)
  }
}

/// Events a frame of the bench produced, for haptics and sound.
nonisolated struct SpinBenchEvents: Sendable {
  var sequenceStarted = false
  var pulseEnded = false
}

/// One spin species on the bench: the engine's `SpinEnsemble` (rotating frame), stepped at a
/// fixed sample rate so the detected signal can be recorded and streamed, plus the lab-frame
/// carrier phase, the M-tip trail, repetition and the sweep-coil ramp.
///
/// Times are species seconds: the proton bench runs in real seconds, the electron bench in
/// seconds scaled by u = γ′ₚ/|γₑ| (`SpinModel.timeUnit`), so both show the same picture.
nonisolated struct SpinBenchRunner: Sendable {
  let species: SpinSpecies
  /// Species seconds per proton second (1 for the proton, 1/658 for the electron).
  let timeUnit: Double
  private(set) var sample: SpinEnsemble
  private(set) var recorder: SpinRecorder
  /// Species seconds since the bench started.
  private(set) var time = 0.0
  /// When the running acquisition started (the sweep coil ramps from here), species seconds.
  private(set) var sequenceStart: Double?
  /// A sequence's record waits for its read pulse (`acquisitionDelay`), the last pulse it
  /// scheduled: the record starts once the ensemble has played it and the bench clock has
  /// reached `acquireAt` (a late spin echo is recorded around its echo, after its π).
  private(set) var awaitingReadPulse = false
  private(set) var acquireAt = 0.0
  private(set) var nextRepeat = 0.25
  /// The carrier (Hz) the frame turns at; equals the line minus Δf while locked.
  private(set) var carrierHz = 0.0
  /// The line (Hz) when the carrier was unlocked, nil while locked. While unlocked the carrier
  /// sits at that line minus the RF offset knob, so field drift shows up as detuning and the
  /// knob still moves the carrier.
  private(set) var heldLine: Double?
  /// Lab-frame angle of the rotating frame (rad, species sense), and how far it turned in the
  /// last advance.
  private(set) var frameAngle = 0.0
  private(set) var frameSweep = 0.0
  /// Recent tips of M (rotating frame), one per bench sample: two proton-equivalent seconds.
  private(set) var trail = SpinTrail(capacity: 800)
  /// The effective centre offset Δf used in the last substep (Hz), including drift and ramp.
  private(set) var effectiveOffset = 0.0
  private var leftover = 0.0
  private var appliedCount = 0
  private var appliedGradient = -1.0
  private var wasPulsing = false

  /// Bench samples per proton-equivalent second (species rate × u): 400 Hz.
  static let baseSampleRate = 400.0
  /// The sample is 10 cm long (the gradient's span), as in `gyre-integration.md` §4.1.
  static let sampleLength = 0.1

  init(species: SpinSpecies, timeUnit: Double, bench: SpinBench) {
    self.species = species
    self.timeUnit = timeUnit
    let count = Self.count(bench)
    sample = SpinEnsemble(
      species: species, count: count, spread: .gradient(teslaPerMetre: bench.gradient, length: Self.sampleLength),
      relaxation: BlochRelaxation(t1: bench.t1, t2: bench.t2, m0: 1))
    appliedCount = count
    appliedGradient = bench.gradient
    let rate = Self.baseSampleRate / timeUnit
    recorder = SpinRecorder(sampleRate: rate, seconds: 1 * timeUnit)
    nextRepeat = 0.25 * timeUnit
  }

  /// Bench samples per species second.
  var sampleRate: Double { recorder.sampleRate }

  /// The length of one record (species seconds): one proton-equivalent second.
  var recordSeconds: Double { Double(recorder.capacity) / recorder.sampleRate }

  static func count(_ bench: SpinBench) -> Int {
    Int(SpinMath.clamp(bench.isochromats.rounded(), SpinKnobs.isochromats.range.lowerBound, SpinKnobs.isochromats.range.upperBound))
  }

  /// Advances `dt` species seconds. `larmorHz` is the line in the field now; `emit` receives
  /// every recorded sample (signal, M_z) in order.
  mutating func advance(
    _ dt: Double, bench: SpinBench, larmorHz: Double, lockCarrier: Bool, repeating: Bool,
    emit: (SIMD2<Double>, Double) -> Void
  ) -> SpinBenchEvents {
    var events = SpinBenchEvents()
    configure(bench)
    if lockCarrier {
      heldLine = nil
    } else if heldLine == nil {
      heldLine = larmorHz
    }
    guard dt > 0, dt.isFinite else {
      frameSweep = 0
      return events
    }
    let h = 1 / sampleRate
    var remaining = leftover + min(dt, 0.25 * timeUnit)
    while remaining >= h {
      if repeating, time >= nextRepeat {
        startSequence(bench)
        events.sequenceStarted = true
      }
      // Δf = f_L − f_rf: the knob, plus field drift against a held carrier, plus the sweep.
      var offset = bench.offsetHz
      if let held = heldLine { offset += larmorHz - held }
      // The carrier sits at the unswept line minus the knob (held: at the held line): the sweep
      // coil moves the line, not the transmitter.
      carrierHz = max(0, larmorHz - offset)
      if bench.ramp != 0, let start = sequenceStart {
        // The coil ramps through one record (the acquisition window), then holds, so the line
        // stays inside the recorded band (2 µT/s · 1 s = 85 Hz < 200 Hz Nyquist).
        let swept = species.larmorHz(field: abs(bench.ramp) * min(time - start, recordSeconds))
        offset += bench.ramp > 0 ? swept : -swept
      }
      effectiveOffset = offset
      sample.offsetHz = offset
      sample.advance(h)
      time += h
      // The sequence's read pulse has played (and, for a late echo, the clock has reached the
      // acquisition start): its record starts with this sample. Half a step of tolerance, as
      // the pulse may land exactly on this step's end.
      if awaitingReadPulse, sample.pending.isEmpty, time >= acquireAt - 0.5 * h {
        awaitingReadPulse = false
        sequenceStart = time
        recorder.trigger()
      }
      frameAngle = SpinMath.wrapAngle(frameAngle + species.precessionSense.sign * 2 * .pi * carrierHz * h)
      // The detected signal is the mean M⊥ (`SpinEnsemble.signal`); one mean serves both.
      let m = sample.meanMagnetization
      let signal = SIMD2(m.x, m.y)
      recorder.append(signal, mz: m.z, rolling: bench.continuous)
      emit(signal, m.z)
      // One trail point per bench sample: a per-frame trail would undersample a fast Rabi
      // nutation into a star polygon.
      trail.append(SIMD3<Float>(m))
      remaining -= h
    }
    leftover = remaining
    // The angle the lab frame turned this advance (unwrapped): more than π per frame strobes.
    frameSweep = species.precessionSense.sign * 2 * .pi * carrierHz * dt
    if wasPulsing, !sample.isPulsing { events.pulseEnded = true }
    wasPulsing = sample.isPulsing
    return events
  }

  /// Plays `bench.sequence` now (hard pulses at exact times) and starts a new record at its read
  /// pulse (`acquisitionDelay`).
  mutating func startSequence(_ bench: SpinBench) {
    configure(bench)
    sample.schedule(bench.sequence.program(tau: bench.echoTau))
    nextRepeat = time + Self.repeatInterval(bench, record: recordSeconds, timeUnit: timeUnit)
    let delay = Self.acquisitionDelay(bench.sequence, tau: bench.echoTau, record: recordSeconds)
    if delay > 0 {
      awaitingReadPulse = true
      acquireAt = time + delay
      sequenceStart = nil
    } else {
      awaitingReadPulse = false
      sequenceStart = time
      recorder.trigger()
    }
  }

  /// Species seconds from a sequence's first pulse to where its record starts, like a
  /// spectrometer acquiring after its read pulse. An FID records from its π/2. An inversion
  /// recovery records from its π/2 at Tᵢ: the FID's amplitude is the measurement, M_z(Tᵢ), and
  /// Tᵢ reaches past one record. A spin echo records from its π/2 while the echo at 2τ fits in
  /// the record with room to decay; otherwise from its π, or, once the echo would sit past the
  /// record's middle, from 2τ minus half a record, so the whole echo is recorded around its
  /// top (τ reaches one record, which put the echo on the record's last sample). A delayed
  /// record never starts before the sequence's last pulse.
  static func acquisitionDelay(_ sequence: SpinSequence, tau: Double, record: Double) -> Double {
    switch sequence {
    case .fid: 0
    case .echo: 2 * tau <= 0.8 * record ? 0 : max(tau, 2 * tau - 0.5 * record)
    case .inversion: tau
    }
  }

  /// Species seconds from one automatic sequence to the next: TR, stretched when TR is shorter
  /// than the sequence. A delayed record (inversion recovery, a late echo) gets its whole
  /// length before the next sequence's first pulse; an early echo gets its echo and a quarter
  /// record to decay. Otherwise a repeat would schedule its pulses before the last ones had
  /// played, the programs would interleave and the read pulse's record would never start
  /// (TR reaches down to 0.5 s, τ and Tᵢ up to 1 s).
  static func repeatInterval(_ bench: SpinBench, record: Double, timeUnit: Double) -> Double {
    let delay = acquisitionDelay(bench.sequence, tau: bench.echoTau, record: record)
    let needed: Double =
      if delay > 0 {
        delay + record
      } else if bench.sequence == .echo {
        2 * bench.echoTau + 0.25 * record
      } else {
        0
      }
    return max(bench.repetition, 0.05 * timeUnit, needed)
  }

  /// A finite pulse at B₁ (π/2 or π about the phase knob): Rabi nutation you can watch.
  mutating func startPulse(flip: Double, bench: SpinBench) {
    configure(bench)
    sample.startPulse(RFPulse(flipAngle: flip, phase: bench.phase))
    sequenceStart = time
    awaitingReadPulse = false
    nextRepeat = time + max(bench.repetition, 0.05 * timeUnit)
    recorder.trigger()
  }

  /// Back to thermal equilibrium (M along B₀), nothing playing.
  mutating func resetMagnetization() {
    sample.reset()
    sequenceStart = nil
    awaitingReadPulse = false
    nextRepeat = time + 0.25 * timeUnit
    trail.clear()
    recorder.clear()
  }

  /// Applies relaxation, drive and spread; a new count or gradient re-spreads the sample (and
  /// returns it to equilibrium).
  private mutating func configure(_ bench: SpinBench) {
    sample.relaxation = BlochRelaxation(t1: bench.t1, t2: bench.t2, m0: 1)
    sample.drive.b1 = bench.b1
    sample.drive.phase = bench.phase
    sample.drive.continuous = bench.continuous
    let count = Self.count(bench)
    if count != appliedCount || bench.gradient != appliedGradient {
      sample.respread(count: count, spread: .gradient(teslaPerMetre: bench.gradient, length: Self.sampleLength))
      appliedCount = count
      appliedGradient = bench.gradient
      trail.clear()
      // The re-spread drops the scheduled pulses: a sequence waiting for its read pulse will
      // not get one, so it must not start a record of the equilibrium sample instead.
      awaitingReadPulse = false
    }
  }

  /// The lab-frame vector R_z(frame angle)·m.
  func lab(_ m: SIMD3<Double>) -> SIMD3<Double> { SpinMath.rotateZ(m, by: frameAngle) }
}
