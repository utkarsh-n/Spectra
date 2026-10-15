import Foundation

nonisolated extension RF {
  /// Small-scale fading applied per tap.
  enum FadingKind: Hashable, Codable, Sendable {
    /// Static taps (no Doppler).
    case none
    /// Rayleigh fading (no line of sight) with Clarke/Jakes Doppler.
    case rayleigh
    /// Rician fading with factor K = (LOS power)/(scattered power), linear.
    case rician(k: Double)
  }

  /// A baseband channel: multipath taps with exponential power-delay profile, Rayleigh/Rician
  /// fading by sum of sinusoids, carrier frequency offset, and AWGN at a given SNR.
  struct ChannelConfig: Hashable, Codable, Sendable {
    /// SNR in dB of the noise against unit signal power (Es/N0 per sample for a unit-power
    /// signal). nil = noiseless.
    var snrDB: Double? = nil
    /// RMS delay spread σ_τ in seconds (0 = single tap).
    var delaySpread: Double = 0
    /// Maximum Doppler shift f_m = v·f/c in Hz (0 = static).
    var dopplerHz: Double = 0
    var fading: FadingKind = .none
    /// Carrier frequency offset in Hz.
    var frequencyOffsetHz: Double = 0
    /// Seed of every random process in the channel.
    var seed: UInt64 = 1
    /// Measure the block's signal power for the SNR (true) or assume unit power (false).
    var measureSignalPower = false

    init(snrDB: Double? = nil, delaySpread: Double = 0, dopplerHz: Double = 0, fading: FadingKind = .none, frequencyOffsetHz: Double = 0, seed: UInt64 = 1) {
      self.snrDB = snrDB
      self.delaySpread = delaySpread
      self.dopplerHz = dopplerHz
      self.fading = fading
      self.frequencyOffsetHz = frequencyOffsetHz
      self.seed = seed
    }

    /// An ideal channel.
    static let ideal = ChannelConfig()

    /// A copy safe to simulate: non-finite or negative delay spread, Doppler and CFO become 0,
    /// a NaN SNR means noiseless, the SNR is clamped to −100…300 dB, a non-finite or negative
    /// Rician K becomes 0 (Rayleigh).
    func sanitized() -> ChannelConfig {
      var c = self
      c.delaySpread = delaySpread.isFinite ? max(0, delaySpread) : 0
      c.dopplerHz = dopplerHz.isFinite ? max(0, dopplerHz) : 0
      c.frequencyOffsetHz = frequencyOffsetHz.isFinite ? frequencyOffsetHz : 0
      if let snr = snrDB { c.snrDB = snr.isNaN ? nil : min(max(snr, -100), 300) }
      if case .rician(let k) = fading { c.fading = .rician(k: k.isFinite ? max(0, k) : 0) }
      return c
    }
  }

  /// One Rayleigh process g(t) = X_c + jX_s by the Zheng–Xiao (2003) sum of sinusoids:
  /// X_c = √(2/M)·Σ cos ψₙ·cos(ω_d t cos αₙ + φ), X_s = √(2/M)·Σ sin ψₙ·cos(ω_d t cos αₙ + φ),
  /// αₙ = (2πn − π + θ)/(4M). Unit mean power, Clarke autocorrelation J₀(2πf_m τ).
  struct SumOfSinusoids: Sendable {
    let sinusoids: Int
    private var omegas: [Double]
    private var phi: Double
    private var cosPsi: [Double]
    private var sinPsi: [Double]

    init(maxDoppler fm: Double, sinusoids m: Int = 16, rng: inout SeededRandom) {
      sinusoids = m
      let theta = rng.uniform(-Double.pi, Double.pi)
      phi = rng.uniform(-Double.pi, Double.pi)
      omegas = (1...m).map { n in
        let alpha = (2 * Double.pi * Double(n) - Double.pi + theta) / (4 * Double(m))
        return 2 * Double.pi * fm * cos(alpha)
      }
      var c = [Double]()
      var s = [Double]()
      for _ in 0..<m {
        let psi = rng.uniform(-Double.pi, Double.pi)
        c.append(cos(psi))
        s.append(sin(psi))
      }
      cosPsi = c
      sinPsi = s
    }

    /// The complex gain at time t (seconds).
    func gain(at t: Double) -> RF.Complex {
      var re = 0.0
      var im = 0.0
      for n in 0..<sinusoids {
        let c = cos(omegas[n] * t + phi)
        re += cosPsi[n] * c
        im += sinPsi[n] * c
      }
      let k = (2 / Double(sinusoids)).squareRoot()
      return RF.Complex(re * k, im * k)
    }
  }

  /// A stateful channel simulator. Feed consecutive blocks; delay-line history, fading time, CFO
  /// phase and noise all continue across calls.
  struct ChannelSimulator: Sendable {
    let config: ChannelConfig
    let sampleRate: Double
    /// Tap delays (samples) and mean powers (sum 1).
    let tapDelays: [Int]
    let tapPowers: [Double]
    private var processes: [SumOfSinusoids]
    private var losPhase: [Double]
    private var losOmega: [Double]
    private var rng: SeededRandom
    private var time = 0.0
    private var cfoPhase = 0.0
    private var historyI: [Float]
    private var historyQ: [Float]
    private let updateInterval: Int

    /// Builds the taps: an exponential power-delay profile over 5σ_τ with at most 32 taps, spaced
    /// one sample apart or, when 5σ_τ spans more than 31 samples, evenly further apart (so a 1 µs
    /// spread at 20 MS/s or 2.66 GS/s keeps its length). The decay constant is then tuned so the
    /// discrete, truncated profile has exactly the requested RMS delay spread σ_τ
    /// (`rmsDelaySpread`), and with it the coherence bandwidth.
    ///
    /// Non-finite or negative settings are read as off (no spread, no Doppler, no CFO, no noise
    /// for a NaN SNR); a non-positive or non-finite sample rate is read as 1 Hz. The delay line
    /// is capped at 2²² samples.
    init(config requested: ChannelConfig, sampleRate requestedRate: Double) {
      let config = requested.sanitized()
      self.config = config
      let sampleRate = requestedRate.isFinite && requestedRate > 0 ? requestedRate : 1
      self.sampleRate = sampleRate
      var rng = SeededRandom(seed: config.seed)
      // 5σ_τ plus the tap-spacing round-up stays inside `maxDelaySamples`.
      let sigmaSamples = min(config.delaySpread * sampleRate, ChannelSimulator.maxDelaySamples / 5.2)
      var delays = [0]
      var powers = [1.0]
      if sigmaSamples > 0.05, sigmaSamples.isFinite {
        let span = 5 * sigmaSamples
        let spacing = max(1, Int((span / 31).rounded(.up)))
        let last = min(31, max(1, Int((span / Double(spacing)).rounded(.up))))
        delays = (0...last).map { $0 * spacing }
        powers = ChannelSimulator.exponentialProfile(delays: delays, rmsSamples: sigmaSamples)
      }
      tapDelays = delays
      tapPowers = powers
      var procs: [SumOfSinusoids] = []
      var losP: [Double] = []
      var losW: [Double] = []
      for _ in delays {
        procs.append(SumOfSinusoids(maxDoppler: config.dopplerHz, rng: &rng))
        losP.append(rng.uniform(-Double.pi, Double.pi))
        losW.append(2 * Double.pi * config.dopplerHz * cos(rng.uniform(-Double.pi, Double.pi)))
      }
      processes = procs
      losPhase = losP
      losOmega = losW
      self.rng = rng
      historyI = [Float](repeating: 0, count: delays.last ?? 0)
      historyQ = [Float](repeating: 0, count: delays.last ?? 0)
      // Re-evaluate fading ~64 times per Doppler period (and at least every 256 samples).
      if config.dopplerHz > 0 {
        updateInterval = Int(min(256, max(1, sampleRate / (64 * config.dopplerHz))))
      } else {
        updateInterval = 256
      }
    }

    /// Longest delay line the simulator builds, samples (2²²).
    static let maxDelaySamples = 4_194_304.0

    /// Normalized powers ∝ exp(−τ/τ₀) on `delays` (samples), with τ₀ chosen by bisection so the
    /// RMS delay spread equals `rmsSamples` (the plain τ₀ = σ_τ would lose 7–9 % to the 5σ_τ
    /// truncation and the sampling).
    private static func exponentialProfile(delays: [Int], rmsSamples target: Double) -> [Double] {
      func profile(_ tau: Double) -> [Double] {
        let p = delays.map { exp(-Double($0) / tau) }
        let total = p.reduce(0, +)
        return p.map { $0 / total }
      }
      func rms(_ tau: Double) -> Double { RF.Fading.rmsDelaySpread(delays: delays.map(Double.init), powers: profile(tau)) }
      // RMS grows monotonically with τ₀, from 0 to that of a flat profile.
      var lo = log(target) - 3
      var hi = log(target) + 6
      guard rms(exp(hi)) > target else { return profile(exp(hi)) }
      for _ in 0..<60 {
        let mid = 0.5 * (lo + hi)
        if rms(exp(mid)) < target { lo = mid } else { hi = mid }
      }
      return profile(exp(0.5 * (lo + hi)))
    }

    /// RMS delay spread of the simulated taps, s (equals `config.delaySpread` unless that is below
    /// 0.05 sample, when the channel is a single tap).
    var rmsDelaySpread: Double {
      RF.Fading.rmsDelaySpread(delays: tapDelays.map { Double($0) / sampleRate }, powers: tapPowers)
    }

    /// The complex gain of tap `k` at time t, including its mean power.
    func tapGain(_ k: Int, at t: Double) -> RF.Complex {
      let a = tapPowers[k].squareRoot()
      switch config.fading {
      case .none:
        return RF.Complex(a)
      case .rayleigh:
        return processes[k].gain(at: t) * a
      case .rician(let kRaw):
        // Only the first tap carries the line of sight (K < 0 was read as 0, i.e. Rayleigh, by
        // `sanitized`).
        let kf = kRaw
        if k == 0 {
          let los = RF.Complex.expj(losOmega[k] * t + losPhase[k]) * (kf / (kf + 1)).squareRoot()
          let nlos = processes[k].gain(at: t) * (1 / (kf + 1)).squareRoot()
          return (los + nlos) * a
        }
        return processes[k].gain(at: t) * a
      }
    }

    mutating func reset() {
      self = ChannelSimulator(config: config, sampleRate: sampleRate)
    }

    /// Passes one block through the channel.
    mutating func process(_ x: IQBuffer, into y: inout IQBuffer) {
      let n = x.count
      if y.count != n { y.resize(to: n) }
      guard n > 0 else { return }
      let taps = tapDelays.count
      let maxDelay = tapDelays.last ?? 0
      let dt = 1 / sampleRate
      // Multipath with piecewise-constant fading coefficients.
      var gains = [RF.Complex](repeating: .zero, count: taps)
      var start = 0
      while start < n {
        let end = min(n, start + updateInterval)
        let tMid = time + (Double(start) + Double(end - start) / 2) * dt
        for k in 0..<taps { gains[k] = tapGain(k, at: tMid) }
        for m in start..<end {
          var accI: Float = 0
          var accQ: Float = 0
          for k in 0..<taps {
            let d = tapDelays[k]
            let src = m - d
            let si: Float
            let sq: Float
            if src >= 0 {
              si = x.i[src]
              sq = x.q[src]
            } else {
              si = historyI[maxDelay + src]
              sq = historyQ[maxDelay + src]
            }
            let gr = Float(gains[k].re)
            let gi = Float(gains[k].im)
            accI += si * gr - sq * gi
            accQ += si * gi + sq * gr
          }
          y.i[m] = accI
          y.q[m] = accQ
        }
        start = end
      }
      // Keep the last maxDelay inputs.
      if maxDelay > 0 {
        if n >= maxDelay {
          for k in 0..<maxDelay {
            historyI[k] = x.i[n - maxDelay + k]
            historyQ[k] = x.q[n - maxDelay + k]
          }
        } else {
          historyI.removeFirst(n)
          historyQ.removeFirst(n)
          historyI.append(contentsOf: x.i)
          historyQ.append(contentsOf: x.q)
        }
      }
      time += Double(n) * dt
      // Carrier frequency offset.
      if config.frequencyOffsetHz != 0 {
        let step = 2 * Double.pi * config.frequencyOffsetHz * dt
        for m in 0..<n {
          let c = Float(cos(cfoPhase))
          let s = Float(sin(cfoPhase))
          let re = y.i[m] * c - y.q[m] * s
          let im = y.i[m] * s + y.q[m] * c
          y.i[m] = re
          y.q[m] = im
          cfoPhase += step
        }
        cfoPhase = cfoPhase.truncatingRemainder(dividingBy: 2 * Double.pi)
      }
      // AWGN.
      if let snr = config.snrDB {
        let signalPower = config.measureSignalPower ? max(x.meanPower, 1e-30) : 1
        let sigma = Float((signalPower / RF.Units.powerRatio(dB: snr) / 2).squareRoot())
        for m in 0..<n {
          let (a, b) = rng.gaussianPair()
          y.i[m] += Float(a) * sigma
          y.q[m] += Float(b) * sigma
        }
      }
    }

    mutating func process(_ x: IQBuffer) -> IQBuffer {
      var y = IQBuffer()
      process(x, into: &y)
      return y
    }
  }
}
