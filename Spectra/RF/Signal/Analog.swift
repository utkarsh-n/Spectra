import Foundation

// MARK: - Theory (rf-physics D.1–D.5)

nonisolated extension RF.AnalogTheory {
  /// AM total-to-carrier power P_t/P_c = 1 + m²/2 (m = 1 → 1.5).
  static func amPowerRatio(modulationIndex m: Double) -> Double { 1 + m * m / 2 }

  /// AM sideband efficiency m²/(2 + m²) (m = 1 → ⅓, m = 0.5 → 1/9).
  static func amSidebandEfficiency(modulationIndex m: Double) -> Double { m * m / (2 + m * m) }

  /// AM occupied bandwidth 2·f_m.
  static func amBandwidth(maxAudioFrequency fm: Double) -> Double { 2 * fm }

  /// FM modulation index β = Δf/f_m.
  static func fmModulationIndex(deviation df: Double, audioFrequency fm: Double) -> Double { df / fm }

  /// Carson's rule B_T ≈ 2(Δf + f_m) (broadcast 75 kHz / 15 kHz → 180 kHz; AMPS 2(12 + 3) = 30 kHz).
  static func carsonBandwidth(deviation df: Double, audioFrequency fm: Double) -> Double { 2 * (df + fm) }

  /// Amplitude of FM/PM spectral line n (relative to the unmodulated carrier): Jₙ(β).
  static func besselLine(order n: Int, beta: Double) -> Double { RF.Special.besselJ(n, beta) }

  /// Lines n = −maxOrder … maxOrder with amplitude Jₙ(β) (J₋ₙ = (−1)ⁿJₙ).
  static func besselLines(beta: Double, maxOrder: Int) -> [(order: Int, amplitude: Double)] {
    (-maxOrder...maxOrder).map { ($0, RF.Special.besselJ($0, beta)) }
  }

  /// Fraction of FM power within ±n sidebands: J₀² + 2·Σ_{k=1}^{n} J_k² (β = 5, n = 6 → 0.993 56).
  static func fmPowerFraction(beta: Double, withinSidebands n: Int) -> Double {
    var s = pow(RF.Special.besselJ(0, beta), 2)
    if n >= 1 { for k in 1...n { s += 2 * pow(RF.Special.besselJ(k, beta), 2) } }
    return s
  }

  /// First zero of J₀ (carrier null), β = 2.404 826.
  static let carrierNullBeta: Double = {
    RF.Numerics.bisect(2.3, 2.5) { RF.Special.besselJ(0, $0) } ?? 2.404_825_557_695_773
  }()

  /// FSK modulation index h = 2Δf/R_b (BLE h = 0.5 at 1 Mb/s → Δf = 250 kHz).
  static func fskModulationIndex(deviation df: Double, bitRate rb: Double) -> Double { 2 * df / rb }

  /// Peak deviation for a given FSK index, Δf = h·R_b/2.
  static func fskDeviation(index h: Double, bitRate rb: Double) -> Double { h * rb / 2 }

  /// Gaussian-filter δ = √(ln 2)/(2π·BT) (TS 45.004; GSM BT 0.3 → 0.441 684).
  static func gaussianDelta(bt: Double) -> Double { log(2.0).squareRoot() / (2 * Double.pi * bt) }

  /// US broadcast FM 100 % modulation deviation, ±75 kHz (47 CFR §73.310).
  static let broadcastFMDeviation = 75_000.0
}

// MARK: - Analog modulation on complex baseband

nonisolated extension RF {
  /// AM, FM and PM.
  enum AnalogModulation: String, CaseIterable, Codable, Hashable, Sendable {
    case am, fm, pm

    var displayName: String {
      switch self {
      case .am: "AM"
      case .fm: "FM"
      case .pm: "PM"
      }
    }
  }

  /// Settings of an analog modulator/demodulator pair.
  struct AnalogSettings: Hashable, Codable, Sendable {
    var kind: AnalogModulation
    /// AM modulation depth m (0…1).
    var amDepth: Double = 0.8
    /// FM peak deviation Δf in Hz for a full-scale (±1) message.
    var fmDeviation: Double = 5_000
    /// PM peak phase deviation k_p in radians for a full-scale message (keep < π).
    var pmDeviation: Double = 1.5
    /// Sample rate of the audio and of the complex baseband, Hz.
    var sampleRate: Double = 48_000

    init(kind: AnalogModulation, sampleRate: Double = 48_000) {
      self.kind = kind
      self.sampleRate = sampleRate
    }
  }

  /// Turns real audio blocks (±1 full scale) into the complex envelope of an AM/FM/PM carrier.
  /// AM: 1 + m·x (carrier included). FM: e^{j2πΔf∫x}. PM: e^{j·k_p·x}. Keeps the FM phase across
  /// blocks.
  struct AnalogModulator: Sendable {
    var settings: AnalogSettings
    private var phase = 0.0

    init(_ settings: AnalogSettings) { self.settings = settings }

    mutating func reset() { phase = 0 }

    mutating func modulate(_ audio: [Float], into out: inout IQBuffer) {
      if out.count != audio.count { out.resize(to: audio.count) }
      switch settings.kind {
      case .am:
        let m = Float(settings.amDepth)
        for n in audio.indices {
          out.i[n] = 1 + m * audio[n]
          out.q[n] = 0
        }
      case .fm:
        let k = 2 * Double.pi * settings.fmDeviation / settings.sampleRate
        for n in audio.indices {
          phase += k * Double(audio[n])
          if phase > Double.pi { phase -= 2 * Double.pi } else if phase < -Double.pi { phase += 2 * Double.pi }
          out.i[n] = Float(cos(phase))
          out.q[n] = Float(sin(phase))
        }
      case .pm:
        let kp = settings.pmDeviation
        for n in audio.indices {
          let p = kp * Double(audio[n])
          out.i[n] = Float(cos(p))
          out.q[n] = Float(sin(p))
        }
      }
    }

    mutating func modulate(_ audio: [Float]) -> IQBuffer {
      var out = IQBuffer()
      modulate(audio, into: &out)
      return out
    }
  }

  /// Recovers audio from a complex envelope. AM: envelope detector with a DC blocker (removes the
  /// carrier term) and 1/m scaling. FM: phase discriminator arg(x[n]·x*[n−1])·f_s/(2πΔf). PM:
  /// unwrapped phase / k_p with a DC blocker against static carrier phase. Stateful across blocks.
  struct AnalogDemodulator: Sendable {
    var settings: AnalogSettings
    private var prevI: Float = 1
    private var prevQ: Float = 0
    private var dc: RF.DSP.DCBlocker
    private var lastPhase = 0.0
    private var unwrapOffset = 0.0
    /// When false, AM subtracts a fixed carrier of 1 instead of DC-blocking (exact for a known
    /// unit carrier; the DC blocker is the realistic choice through a channel).
    var dcBlock = true

    init(_ settings: AnalogSettings, dcCornerHz: Double = 20) {
      self.settings = settings
      dc = RF.DSP.DCBlocker(cornerHz: dcCornerHz, sampleRate: settings.sampleRate)
    }

    mutating func reset() {
      prevI = 1
      prevQ = 0
      dc.reset()
      lastPhase = 0
      unwrapOffset = 0
    }

    mutating func demodulate(_ iq: IQBuffer, into audio: inout [Float]) {
      if audio.count != iq.count { audio = [Float](repeating: 0, count: iq.count) }
      switch settings.kind {
      case .am:
        let inv = 1 / max(settings.amDepth, 1e-6)
        for n in 0..<iq.count {
          let env = Double((iq.i[n] * iq.i[n] + iq.q[n] * iq.q[n]).squareRoot())
          let ac = dcBlock ? dc.process(env) : env - 1
          audio[n] = Float(ac * inv)
        }
      case .fm:
        let k = settings.sampleRate / (2 * Double.pi * max(settings.fmDeviation, 1e-9))
        for n in 0..<iq.count {
          let x = iq.i[n]
          let y = iq.q[n]
          // x[n]·conj(x[n−1])
          let re = Double(x * prevI + y * prevQ)
          let im = Double(y * prevI - x * prevQ)
          audio[n] = Float(atan2(im, re) * k)
          prevI = x
          prevQ = y
        }
      case .pm:
        let inv = 1 / max(settings.pmDeviation, 1e-9)
        for n in 0..<iq.count {
          let p = atan2(Double(iq.q[n]), Double(iq.i[n]))
          let d = p - lastPhase
          if d > Double.pi {
            unwrapOffset -= 2 * Double.pi
          } else if d < -Double.pi {
            unwrapOffset += 2 * Double.pi
          }
          lastPhase = p
          let unwrapped = p + unwrapOffset
          audio[n] = Float((dcBlock ? dc.process(unwrapped) : unwrapped) * inv)
        }
      }
    }

    mutating func demodulate(_ iq: IQBuffer) -> [Float] {
      var out = [Float]()
      demodulate(iq, into: &out)
      return out
    }
  }
}
