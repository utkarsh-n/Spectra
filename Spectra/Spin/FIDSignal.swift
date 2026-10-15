import Accelerate
import Foundation

/// One free induction decay: M⊥(t) = A e^(−t/T₂*) e^(i(φ + s·2πf t)), s = −1 for
/// clockwise precession (γ > 0) and +1 for counterclockwise (γ < 0).
nonisolated struct FIDParameters: Sendable, Hashable, Codable {
  /// True precession frequency f_L (Hz, positive).
  var frequencyHz: Double
  /// Initial transverse amplitude A (M₀ units, or volts after scaling).
  var amplitude = 1.0
  /// Decay time T₂* (s). Infinite means no decay.
  var t2Star = 0.075
  /// Phase φ at t = 0 (radians).
  var phase = 0.0
  /// Sense of precession; sets the sign of the baseband frequency.
  var sense = PrecessionSense.clockwise

  init(frequencyHz: Double, amplitude: Double = 1, t2Star: Double = 0.075, phase: Double = 0, sense: PrecessionSense = .clockwise) {
    self.frequencyHz = abs(frequencyHz)
    self.amplitude = amplitude
    self.t2Star = t2Star
    self.phase = phase
    self.sense = sense
  }

  /// The FID of `species` in a field of magnitude `field` tesla.
  init(species: SpinSpecies, field: Double, t2Star: Double = 0.075, amplitude: Double = 1, phase: Double = 0) {
    self.init(
      frequencyHz: species.larmorHz(field: field), amplitude: amplitude, t2Star: t2Star, phase: phase,
      sense: species.precessionSense)
  }

  /// Full width at half maximum of the line, 1/(πT₂*) (Hz).
  var linewidthHz: Double { t2Star.isFinite && t2Star > 0 ? 1 / (.pi * t2Star) : 0 }
}

/// Sampled FID signals: complex baseband (heterodyned) and real audio at true pitch.
nonisolated enum FIDSignal {
  /// The envelope A e^(−t/T₂*) for t ≥ 0 (0 before the pulse).
  static func envelope(_ p: FIDParameters, at t: Double) -> Double {
    guard t >= 0 else { return 0 }
    return p.t2Star.isFinite && p.t2Star > 0 ? p.amplitude * exp(-t / p.t2Star) : p.amplitude
  }

  /// Complex baseband samples s(t) = A e^(−t/T₂*) e^(i(φ + s·2π(f − f_ref)t)) at
  /// t = startTime + n/fs: the rotating-frame view at `referenceHz` (I = x, Q = y).
  static func baseband(
    _ p: FIDParameters, referenceHz: Double, sampleRate: Double, count: Int, startTime: Double = 0
  ) -> [SIMD2<Double>] {
    guard sampleRate > 0, count > 0 else { return [] }
    let w = p.sense.sign * 2 * .pi * (p.frequencyHz - referenceHz)
    return (0..<count).map { n in
      let t = startTime + Double(n) / sampleRate
      let a = envelope(p, at: t)
      let theta = p.phase + w * t
      return SIMD2(a * cos(theta), a * sin(theta))
    }
  }

  /// Real samples A e^(−t/T₂*) cos(φ + s·2πf t) at the true frequency: what a pickup coil
  /// would see. Earth-field protons (~2.1 kHz) play at their true pitch. Check
  /// `isRepresentable` first: above fs/2 these samples alias.
  static func audio(_ p: FIDParameters, sampleRate: Double, count: Int, startTime: Double = 0) -> [Float] {
    guard sampleRate > 0, count > 0 else { return [] }
    let w = p.sense.sign * 2 * .pi * p.frequencyHz
    return (0..<count).map { n in
      let t = startTime + Double(n) / sampleRate
      return Float(envelope(p, at: t) * cos(p.phase + w * t))
    }
  }

  /// True when a real tone at `frequency` can be sampled at `sampleRate` without aliasing.
  static func isRepresentable(frequency: Double, sampleRate: Double) -> Bool {
    abs(frequency) < 0.5 * sampleRate
  }
}

/// A spectrum on a frequency axis: the FID's line.
nonisolated struct FIDSpectrum: Sendable, Hashable {
  /// Frequency of each bin (Hz), ascending. Baseband spectra run −fs/2 ..< fs/2.
  var frequencies: [Double]
  var real: [Double]
  var imaginary: [Double]

  /// |S(f)| per bin.
  var magnitude: [Double] { zip(real, imaginary).map { hypot($0, $1) } }

  /// Frequency of the largest |S| (Hz).
  var peakFrequency: Double {
    var best = 0
    var bestValue = -1.0
    for i in frequencies.indices {
      let v = real[i] * real[i] + imaginary[i] * imaginary[i]
      if v > bestValue {
        bestValue = v
        best = i
      }
    }
    return frequencies.isEmpty ? 0 : frequencies[best]
  }

  /// The analytic line: the continuous Fourier transform of the baseband FID,
  /// S(f) = A e^(iφ)/(1/T₂* + i2π(f − f₀)), f₀ = s(f_L − f_ref). Peak |S| = A·T₂*; the real
  /// part is the absorption Lorentzian with FWHM 1/(πT₂*).
  static func lorentzian(_ p: FIDParameters, referenceHz: Double, frequencies: [Double]) -> FIDSpectrum {
    let f0 = p.sense.sign * (p.frequencyHz - referenceHz)
    let rate = p.t2Star.isFinite && p.t2Star > 0 ? 1 / p.t2Star : 0
    var re = [Double]()
    var im = [Double]()
    re.reserveCapacity(frequencies.count)
    im.reserveCapacity(frequencies.count)
    let c = p.amplitude * cos(p.phase)
    let s = p.amplitude * sin(p.phase)
    for f in frequencies {
      let x = 2 * .pi * (f - f0)
      let d = rate * rate + x * x
      guard d > 0 else {
        re.append(.infinity)
        im.append(0)
        continue
      }
      // (c + is)(rate − ix)/d
      re.append((c * rate + s * x) / d)
      im.append((s * rate - c * x) / d)
    }
    return FIDSpectrum(frequencies: frequencies, real: re, imaginary: im)
  }

  /// The discrete spectrum of sampled baseband `samples` (vDSP DFT, forward e^(−i2πkn/N)),
  /// zero-filled to a power of two ≥ 16, centred (fftshift) and scaled by 1/fs so it
  /// approximates the continuous transform (peak ≈ A·T₂* for a long record).
  static func transform(_ samples: [SIMD2<Double>], sampleRate: Double) -> FIDSpectrum? {
    guard sampleRate > 0, !samples.isEmpty else { return nil }
    var n = 16
    while n < samples.count { n *= 2 }
    var inRe = [Double](repeating: 0, count: n)
    var inIm = [Double](repeating: 0, count: n)
    for (i, s) in samples.enumerated() {
      inRe[i] = s.x
      inIm[i] = s.y
    }
    guard
      let dft = try? vDSP.DiscreteFourierTransform(
        count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)
    else { return nil }
    var outRe = [Double](repeating: 0, count: n)
    var outIm = [Double](repeating: 0, count: n)
    dft.transform(inputReal: inRe, inputImaginary: inIm, outputReal: &outRe, outputImaginary: &outIm)
    let half = n / 2
    let scale = 1 / sampleRate
    var freqs = [Double](repeating: 0, count: n)
    var re = [Double](repeating: 0, count: n)
    var im = [Double](repeating: 0, count: n)
    for j in 0..<n {
      let k = (j + half) % n  // bin k at shifted position j
      freqs[j] = Double(j - half) * sampleRate / Double(n)
      re[j] = outRe[k] * scale
      im[j] = outIm[k] * scale
    }
    return FIDSpectrum(frequencies: freqs, real: re, imaginary: im)
  }

  /// One-sided spectrum 0 … fs/2 of a real record (the audio FID at true pitch), Hann
  /// windowed, zero-filled to a power of two, scaled by 1/fs. The line sits at f_L.
  static func transform(real samples: [Float], sampleRate: Double) -> FIDSpectrum? {
    guard !samples.isEmpty else { return nil }
    let w = SpinAnalysis.hann(count: samples.count)
    let complex = samples.enumerated().map { SIMD2(Double($0.element) * w[$0.offset], 0) }
    guard let full = transform(complex, sampleRate: sampleRate) else { return nil }
    let start = full.frequencies.firstIndex { $0 >= 0 } ?? 0
    return FIDSpectrum(
      frequencies: Array(full.frequencies[start...]), real: Array(full.real[start...]),
      imaginary: Array(full.imaginary[start...]))
  }
}

/// A streaming FID voice for the synth: a phase-continuous carrier at an audible frequency
/// (the true Larmor pitch, or the mapped one) under a T₂* ring-down envelope. Pure value
/// type: the audio thread owns one copy and calls `render`; the main actor sets targets
/// through the synth's atomics (`gyre-integration.md` §4.9).
nonisolated struct FIDOscillator: Sendable {
  /// How the envelope behaves between pulses.
  enum EnvelopeMode: Sendable, Hashable, Codable {
    /// One ring-down per `trigger()`.
    case ringDown
    /// A steady tone at full level (no decay): "hold the line".
    case sustained
    /// Re-pulses every `interval` seconds, like a real Earth's-field rig repeating its scan.
    case repeating(interval: Double)
    /// Follows `envelopeTarget`, set at control rate from a simulation's |M⊥(t)|
    /// (`gyre-integration.md` §4.1 FIDVoice: carrier at audio rate, envelope at control rate).
    case follow
  }

  var sampleRate: Double
  /// The frequency to glide toward (Hz).
  var targetFrequency: Double
  /// Glide time constant for frequency changes (s). 0.25 s keeps magnetometer noise from
  /// warbling the tone (`gyre-integration.md` §4.1).
  var glideTime = 0.25
  /// Envelope decay T₂* (s).
  var t2Star: Double
  var mode: EnvelopeMode
  /// Output gain.
  var level: Double = 0.25
  /// Attack ramp after a pulse (s), so the restart does not click.
  var attack = 0.002
  /// In `.follow` mode: the envelope to glide toward (0…1), e.g. the Bloch ensemble's |M⊥|.
  var envelopeTarget = 0.0
  /// In `.follow` mode: glide time toward `envelopeTarget` (s), short enough to keep the
  /// echo's shape, long enough to avoid zipper noise at a 60 Hz control rate.
  var followTime = 0.008

  /// The current, glided frequency (Hz).
  private(set) var frequency: Double
  /// Carrier phase in cycles, 0 ..< 1.
  private(set) var phase = 0.0
  /// Seconds since the last pulse.
  private(set) var sincePulse = Double.infinity
  private var peak = 0.0
  private var followed = 0.0

  init(sampleRate: Double = 48_000, frequency: Double, t2Star: Double = 0.075, mode: EnvelopeMode = .ringDown) {
    self.sampleRate = sampleRate
    self.targetFrequency = frequency
    self.frequency = frequency
    self.t2Star = t2Star
    self.mode = mode
  }

  /// A π/2 pulse: restarts the ring-down at `amplitude`.
  mutating func trigger(amplitude: Double = 1) {
    sincePulse = 0
    peak = amplitude
  }

  /// The envelope right now (0…amplitude).
  var envelope: Double {
    if case .sustained = mode { return peak }
    if case .follow = mode { return followed }
    guard sincePulse.isFinite else { return 0 }
    let ramp = attack > 0 ? min(sincePulse / attack, 1) : 1
    let decay = t2Star.isFinite && t2Star > 0 ? exp(-sincePulse / t2Star) : 1
    return peak * ramp * decay
  }

  /// Renders `count` samples.
  mutating func render(_ count: Int) -> [Float] {
    var out = [Float](repeating: 0, count: max(count, 0))
    out.withUnsafeMutableBufferPointer { render(into: $0) }
    return out
  }

  /// Renders into `buffer` without allocating (audio-thread safe).
  mutating func render(into buffer: UnsafeMutableBufferPointer<Float>) {
    for i in buffer.indices { buffer[i] = advance().value }
  }

  /// Produces one sample and the envelope it was drawn with, then advances by 1/fs.
  mutating func advance() -> (value: Float, envelope: Double) {
    guard sampleRate > 0 else { return (0, 0) }
    let dt = 1 / sampleRate
    if case .repeating(let interval) = mode, interval > 0, sincePulse >= interval || !sincePulse.isFinite {
      trigger(amplitude: peak > 0 ? peak : 1)
    }
    // A non-finite target (a NaN field upstream) is ignored rather than latched: once the
    // phase or envelope went NaN the voice would stay silent-NaN for good.
    let target = targetFrequency.isFinite ? targetFrequency : frequency
    if glideTime > 0 {
      frequency += (target - frequency) * (1 - exp(-dt / glideTime))
    } else {
      frequency = target
    }
    if !frequency.isFinite { frequency = 0 }
    if case .follow = mode {
      let goal = envelopeTarget.isFinite ? envelopeTarget : followed
      followed += (goal - followed) * (followTime > 0 ? 1 - exp(-dt / followTime) : 1)
      if !followed.isFinite { followed = 0 }
    }
    let env = envelope
    let value = Float(level * env * sin(2 * .pi * phase))
    phase += frequency * dt
    phase -= phase.rounded(.down)
    if !phase.isFinite { phase = 0 }
    sincePulse += dt
    return (value.isFinite ? value : 0, env)
  }
}
