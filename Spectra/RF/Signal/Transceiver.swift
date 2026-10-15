import Foundation

nonisolated extension RF {
  /// How a waveform is sampled and framed in the simulator. Shared by `Transmitter` and
  /// `Receiver` (build both from the same settings) and by `BasebandLink`.
  struct WaveformSettings: Hashable, Codable, Sendable {
    var waveform: Waveform
    /// Replaces the data modulation of linear, DSSS and OFDM waveforms.
    var modulation: DigitalModulation?
    /// Oversampling of linear and FSK waveforms (≥ 2).
    var samplesPerSymbol: Int = 8
    /// Oversampling of DSSS chips (rectangular chips, ≥ 1).
    var samplesPerChip: Int = 2
    /// Approximate samples per frame; frames hold whole symbols (OFDM: whole OFDM symbols).
    var targetSamples: Int = 4096

    init(waveform: Waveform, modulation: DigitalModulation? = nil) {
      self.waveform = waveform
      self.modulation = modulation
    }

    /// Audio rate of analog waveforms (Hz).
    static let audioRate = 48_000.0

    /// The data modulation in use (nil for analog, FSK and tone).
    var dataModulation: DigitalModulation? {
      switch waveform {
      case .linear(let m, _, _), .dsss(let m, _, _), .ofdm(let m, _): modulation ?? m
      default: nil
      }
    }

    /// Oversampling actually used: `samplesPerSymbol` clamped to 2…64, `samplesPerChip` to 1…64.
    var sps: Int { min(max(2, samplesPerSymbol), 64) }
    var spc: Int { min(max(1, samplesPerChip), 64) }

    /// Analog only: IQ rate = 48 kHz × this factor, chosen so the IQ rate is at least 2.5×
    /// Carson's bandwidth (FM) — 1 for AM. Capped at `maxAnalogOversampling` (3.07 MS/s, enough for
    /// ±600 kHz deviation); a wider FM signal aliases instead of building a huge interpolator.
    var analogOversampling: Int {
      if case .analogFM(let dev, let audio) = waveform {
        let ratio = (2.5 * RF.AnalogTheory.carsonBandwidth(deviation: abs(dev), audioFrequency: abs(audio)) / Self.audioRate).rounded(.up)
        guard ratio.isFinite else { return ratio.isNaN ? 1 : Self.maxAnalogOversampling }
        return Int(min(max(ratio, 1), Double(Self.maxAnalogOversampling)))
      }
      return 1
    }

    /// Upper bound of `analogOversampling`.
    static let maxAnalogOversampling = 64

    /// Real-world sample rate the simulated samples stand for, Hz.
    var sampleRate: Double {
      switch waveform {
      case .tone: 100_000
      case .analogAM, .analogFM: Self.audioRate * Double(analogOversampling)
      case .linear(_, let r, _), .fsk(_, _, let r): r * Double(sps)
      case .dsss(_, _, let chipRate): chipRate * Double(spc)
      case .ofdm(_, let c): c.sampleRate
      case .chirp(let b, _): 2 * Self.chirpBandwidth(b)
      }
    }

    /// FMCW only: samples per chirp, T·f_s = 2BT rounded and clamped to 16…2²⁰ (4096 if T or B
    /// is not a positive finite number).
    var chirpSamples: Int {
      guard case .chirp(let b, let t) = waveform else { return 0 }
      let m = (t * 2 * Self.chirpBandwidth(b)).rounded()
      guard m.isFinite, t > 0 else { return 4096 }
      return Int(min(max(m, 16), 1_048_576))
    }

    /// The sweep width actually simulated: |B|, or 1 MHz if B is zero or not finite.
    static func chirpBandwidth(_ b: Double) -> Double { b.isFinite && b != 0 ? abs(b) : 1e6 }

    /// Data symbol rate, Hz (OFDM: data subcarrier symbols per second; 0 for analog and tone).
    var symbolRate: Double {
      switch waveform {
      case .linear(_, let r, _), .fsk(_, _, let r): r
      case .dsss(_, let chips, let chipRate): chipRate / Double((RF.SpreadingCode.forLength(chips) ?? .mSequence127).length)
      case .ofdm(_, let c): c.sampleRate / Double(c.symbolLength) * Double(c.dataSubcarriers.count)
      default: 0
      }
    }

    /// Bandwidth the signal occupies, Hz: (1 + β)·R_s for RRC, 2R_s main lobe for rectangular
    /// pulses and DSSS chips, Carson for FM/FSK, 2W for AM, used subcarriers × Δf for OFDM.
    var occupiedBandwidth: Double {
      switch waveform {
      case .tone: 0
      case .analogAM: 2 * 5_000
      case .analogFM(let dev, let audio): RF.AnalogTheory.carsonBandwidth(deviation: dev, audioFrequency: audio)
      case .linear(_, let r, .rootRaisedCosine(let beta)): (1 + beta) * r
      case .linear(_, let r, .rectangular): 2 * r
      case .fsk(let h, _, let r): RF.AnalogTheory.carsonBandwidth(deviation: RF.AnalogTheory.fskDeviation(index: h, bitRate: r), audioFrequency: r / 2)
      case .dsss(_, _, let chipRate): 2 * chipRate
      case .ofdm(_, let c): c.occupiedBandwidth
      case .chirp(let b, _): Self.chirpBandwidth(b)
      }
    }

    /// Symbols, samples and bits of one frame.
    struct FramePlan: Hashable, Sendable {
      /// Data symbols per frame (OFDM: OFDM symbols including training).
      var symbols: Int
      var samples: Int
      var bits: Int
    }

    /// The frame every `Transmitter.modulate(bits:)` call produces. Analog and tone frames are
    /// sized by the caller (audio block length / sample count), so their plan has no bits.
    var framePlan: FramePlan {
      // 64 … 2²⁰ samples per frame.
      let target = min(max(64, targetSamples), 1 << 20)
      let k = dataModulation?.bitsPerSymbol ?? 1
      switch waveform {
      case .tone, .analogAM, .analogFM, .chirp:
        return FramePlan(symbols: 0, samples: target, bits: 0)
      case .linear:
        let n = max(1, target / sps)
        return FramePlan(symbols: n, samples: n * sps, bits: n * k)
      case .fsk:
        let n = max(1, target / sps)
        return FramePlan(symbols: n, samples: n * sps, bits: n)
      case .dsss(_, let chips, _):
        let perSymbol = (RF.SpreadingCode.forLength(chips) ?? .mSequence127).length * spc
        let n = max(1, target / perSymbol)
        return FramePlan(symbols: n, samples: n * perSymbol, bits: n * k)
      case .ofdm(_, let c):
        let n = max(c.trainingSymbols + 1, target / c.symbolLength)
        return FramePlan(symbols: n, samples: n * c.symbolLength, bits: (n - c.trainingSymbols) * c.dataSubcarriers.count * k)
      }
    }

    /// Converts the user-facing SNR to the per-sample SNR of unit-power samples (dB): digital
    /// waveforms take E_s/N₀ per data symbol; analog and tone take the carrier-to-noise ratio in
    /// the channel bandwidth.
    func perSampleSNR(_ snrDB: Double) -> Double {
      switch waveform {
      case .tone: return snrDB
      case .analogAM, .analogFM:
        // CNR in the channel bandwidth; a zero-width signal (FM with no deviation and no audio)
        // falls back to the CNR per sample instead of an infinite noise power.
        let b = occupiedBandwidth
        return b > 0 ? snrDB - 10 * log10(sampleRate / b) : snrDB
      case .linear, .fsk: return snrDB - 10 * log10(Double(sps))
      case .dsss(_, let chips, _):
        let perSymbol = (RF.SpreadingCode.forLength(chips) ?? .mSequence127).length * spc
        return snrDB - 10 * log10(Double(perSymbol))
      case .ofdm(_, let c):
        return snrDB + 10 * log10(Double(c.usedSubcarriers.count) / Double(c.fftSize))
      case .chirp:
        // CNR in the swept bandwidth B, sampled at 2B.
        return snrDB - 10 * log10(sampleRate / occupiedBandwidth)
      }
    }
  }

  /// The transmit half of a waveform: bits (or audio) in, unit-power complex baseband out.
  /// Stateful and seamless across calls (filter histories, phases). Patch's Modulator node.
  struct Transmitter: Sendable {
    let settings: WaveformSettings
    private var linear: LinearTX?
    private var fsk: FSKModulator?
    private var dsss: DSSSTX?
    private var ofdm: OFDMTX?
    private var analog: AnalogTX?
    private var chirp: ChirpTX?

    init(_ settings: WaveformSettings) {
      self.settings = settings
      switch settings.waveform {
      case .tone: break
      case .chirp(let b, _):
        chirp = ChirpTX(bandwidth: WaveformSettings.chirpBandwidth(b), samplesPerChirp: settings.chirpSamples)
      case .analogAM, .analogFM: analog = AnalogTX(settings)
      case .linear(_, _, let pulse): linear = LinearTX(modulation: settings.dataModulation!, sps: settings.sps, pulse: pulse)
      case .fsk(let h, let bt, _): fsk = FSKModulator(FSKSettings(index: h, bt: bt, samplesPerSymbol: settings.sps))
      case .dsss(_, let chips, _): dsss = DSSSTX(modulation: settings.dataModulation!, chips: chips, spc: settings.spc)
      case .ofdm(_, let c): ofdm = OFDMTX(modulation: settings.dataModulation!, config: c)
      }
    }

    /// Modulates bits. Returns the samples and the ideal symbol points (for EVM; FSK: ±1 per
    /// bit). Linear, FSK and DSSS take any whole number of symbols; OFDM pads to whole OFDM
    /// symbols and prepends a training symbol in preamble mode — pass `settings.framePlan.bits`
    /// bits for frames the `Receiver` can follow. Analog and tone waveforms return empty buffers.
    mutating func modulate(bits: [UInt8]) -> (samples: IQBuffer, symbols: IQBuffer) {
      if linear != nil { return linear!.modulate(bits) }
      if fsk != nil {
        let samples = fsk!.modulate(bits: bits)
        return (samples, IQBuffer(i: bits.map { $0 & 1 == 1 ? 1 : -1 }, q: [Float](repeating: 0, count: bits.count)))
      }
      if let dsss { return dsss.modulate(bits) }
      if let ofdm { return ofdm.modulate(bits) }
      return (IQBuffer(), IQBuffer())
    }

    /// Modulates 48 kHz audio (±1) for AM/FM; the output has `audio.count × analogOversampling`
    /// samples. Returns an empty buffer for digital waveforms.
    mutating func modulate(audio: [Float]) -> IQBuffer {
      analog != nil ? analog!.modulate(audio) : IQBuffer()
    }

    /// `count` samples of the unmodulated carrier (unit power).
    func carrier(count: Int) -> IQBuffer {
      IQBuffer(i: [Float](repeating: 1, count: max(0, count)), q: [Float](repeating: 0, count: max(0, count)))
    }

    /// FMCW: the next `count` samples of the repeating sweep (unit power, phase-continuous across
    /// calls and chirps). Empty for other waveforms.
    mutating func sweep(count: Int) -> IQBuffer {
      chirp != nil ? chirp!.next(count: count) : IQBuffer()
    }
  }

  /// What a `Receiver` recovered from one block.
  struct ReceivedBlock: Sendable {
    /// Decision-point samples: matched-filtered, despread or OFDM-equalized symbols (FSK: the IQ
    /// sample at each symbol centre).
    var symbols = IQBuffer()
    /// Hard-decision bits, aligned with `symbols`.
    var bits: [UInt8] = []
    /// Demodulated 48 kHz audio (analog waveforms).
    var audio: [Float]?
    /// OFDM channel estimate on the used subcarriers of the last symbol.
    var channelEstimate: IQBuffer?
  }

  /// The receive half: complex baseband in, symbols/bits (or audio) out. Accepts blocks of any
  /// length and keeps partial symbols for the next call, so it can sit behind a Patch Channel
  /// node; outputs come out in transmit order with a fixed latency.
  struct Receiver: Sendable {
    let settings: WaveformSettings
    private var linear: LinearRX?
    private var fsk: FSKRX?
    private var dsss: DSSSRX?
    private var ofdm: OFDMRX?
    private var analog: AnalogRX?

    /// `estimateAveraging` (OFDM): number of estimates the channel tracker averages (1 = plain
    /// LS); `tracksCommonPhase` removes per-symbol common phase error (needed with CFO/Doppler).
    init(_ settings: WaveformSettings, estimateAveraging: Double = 16, tracksCommonPhase: Bool = true) {
      self.settings = settings
      switch settings.waveform {
      case .tone, .chirp: break
      case .analogAM, .analogFM: analog = AnalogRX(settings)
      case .linear(_, _, let pulse): linear = LinearRX(modulation: settings.dataModulation!, sps: settings.sps, pulse: pulse)
      case .fsk(let h, let bt, _): fsk = FSKRX(FSKSettings(index: h, bt: bt, samplesPerSymbol: settings.sps))
      case .dsss(_, let chips, _): dsss = DSSSRX(modulation: settings.dataModulation!, chips: chips, spc: settings.spc)
      case .ofdm(_, let c):
        ofdm = OFDMRX(modulation: settings.dataModulation!, config: c, frameSymbols: settings.framePlan.symbols,
                      averaging: estimateAveraging, tracksPhase: tracksCommonPhase)
      }
    }

    mutating func receive(_ iq: IQBuffer) -> ReceivedBlock {
      if linear != nil { return linear!.receive(iq) }
      if fsk != nil { return fsk!.receive(iq) }
      if dsss != nil { return dsss!.receive(iq) }
      if ofdm != nil { return ofdm!.receive(iq) }
      if analog != nil { return ReceivedBlock(audio: analog!.demodulate(iq)) }
      return ReceivedBlock()
    }
  }
}

// MARK: - Waveform halves

nonisolated extension RF.Transmitter {
  fileprivate struct LinearTX: Sendable {
    let constellation: RF.Constellation
    let sps: Int
    var filter: RF.DSP.ComplexFIRFilter

    init(modulation: RF.DigitalModulation, sps: Int, pulse: RF.PulseShape) {
      constellation = RF.Constellation(modulation)
      self.sps = sps
      filter = RF.DSP.ComplexFIRFilter(taps: RF.Receiver.pulseTaps(pulse, sps: sps))
    }

    mutating func modulate(_ bits: [UInt8]) -> (RF.IQBuffer, RF.IQBuffer) {
      let s = constellation.map(bits: bits)
      var up = RF.DSP.zeroStuff(s, factor: sps)
      up.scale(by: Float(sps).squareRoot())
      var tx = RF.IQBuffer()
      filter.process(up, into: &tx)
      return (tx, s)
    }
  }

  fileprivate struct DSSSTX: Sendable {
    let constellation: RF.Constellation
    let spreader: RF.DSSSSpreader

    init(modulation: RF.DigitalModulation, chips: Int, spc: Int) {
      constellation = RF.Constellation(modulation)
      spreader = RF.Receiver.oversampledSpreader(chips: chips, spc: spc)
    }

    func modulate(_ bits: [UInt8]) -> (RF.IQBuffer, RF.IQBuffer) {
      let s = constellation.map(bits: bits)
      return (spreader.spread(s), s)
    }
  }

  fileprivate struct OFDMTX: Sendable {
    let constellation: RF.Constellation
    let modulator: RF.OFDMModulator?

    init(modulation: RF.DigitalModulation, config: RF.OFDMConfig) {
      constellation = RF.Constellation(modulation)
      modulator = RF.OFDMModulator(config: config)
    }

    func modulate(_ bits: [UInt8]) -> (RF.IQBuffer, RF.IQBuffer) {
      guard let modulator else { return (RF.IQBuffer(), RF.IQBuffer()) }
      let s = constellation.map(bits: bits)
      return (modulator.modulate(s), s)
    }
  }

  /// Sawtooth linear FM: instantaneous frequency −B/2 + B·m/M at sample m of each M-sample
  /// chirp, sampled at 2B, phase accumulated in double precision.
  fileprivate struct ChirpTX: Sendable {
    let bandwidth: Double
    let samplesPerChirp: Int
    var position = 0
    var phase = 0.0

    init(bandwidth: Double, samplesPerChirp: Int) {
      self.bandwidth = bandwidth
      self.samplesPerChirp = max(1, samplesPerChirp)
    }

    mutating func next(count: Int) -> RF.IQBuffer {
      var out = RF.IQBuffer(count: max(0, count))
      let m = Double(samplesPerChirp)
      // f/f_s = (−B/2 + B·k/M)/(2B) = −1/4 + k/(2M) cycles per sample.
      for n in 0..<out.count {
        out.i[n] = Float(cos(phase))
        out.q[n] = Float(sin(phase))
        phase += 2 * Double.pi * (-0.25 + Double(position) / (2 * m))
        if phase > Double.pi { phase -= 2 * Double.pi } else if phase < -Double.pi { phase += 2 * Double.pi }
        position += 1
        if position == samplesPerChirp { position = 0 }
      }
      return out
    }
  }

  fileprivate struct AnalogTX: Sendable {
    var modulator: RF.AnalogModulator
    var up: RF.DSP.Interpolator

    init(_ settings: RF.WaveformSettings) {
      let s = RF.Receiver.analogSettings(settings)
      modulator = RF.AnalogModulator(s)
      up = RF.DSP.Interpolator(factor: settings.analogOversampling)
    }

    mutating func modulate(_ audio: [Float]) -> RF.IQBuffer { modulator.modulate(up.process(audio)) }
  }
}

nonisolated extension RF.Receiver {
  /// Transmit/receive pulse of a linear modulation (16-symbol RRC keeps truncation ISI below
  /// −50 dB, so 4096-QAM is error-free without noise).
  static func pulseTaps(_ pulse: RF.PulseShape, sps: Int) -> [Float] {
    switch pulse {
    case .rootRaisedCosine(let beta): RF.PulseShaper(samplesPerSymbol: sps, rolloff: beta, spanSymbols: 16).taps
    case .rectangular: RF.PulseShaper(rectangularSamplesPerSymbol: sps).taps
    }
  }

  /// Spreader whose code chips are each repeated `spc` times.
  static func oversampledSpreader(chips: Int, spc: Int) -> RF.DSSSSpreader {
    let code = RF.SpreadingCode.forLength(chips) ?? .mSequence127
    return RF.DSSSSpreader(code: RF.SpreadingCode(chips: code.chips.flatMap { repeatElement($0, count: spc) }, name: code.name))
  }

  /// AM/FM settings at the IQ rate.
  static func analogSettings(_ settings: RF.WaveformSettings) -> RF.AnalogSettings {
    var s = RF.AnalogSettings(kind: .am)
    switch settings.waveform {
    case .analogAM(let depth):
      s.amDepth = depth
    case .analogFM(let deviation, _):
      s = RF.AnalogSettings(kind: .fm)
      s.fmDeviation = deviation
    default:
      break
    }
    s.sampleRate = RF.WaveformSettings.audioRate * Double(settings.analogOversampling)
    return s
  }

  fileprivate struct LinearRX: Sendable {
    let constellation: RF.Constellation
    let sps: Int
    var filter: RF.DSP.ComplexFIRFilter
    let delay: Int
    var counter = 0

    init(modulation: RF.DigitalModulation, sps: Int, pulse: RF.PulseShape) {
      constellation = RF.Constellation(modulation)
      self.sps = sps
      let taps = RF.Receiver.pulseTaps(pulse, sps: sps)
      filter = RF.DSP.ComplexFIRFilter(taps: taps)
      delay = taps.count - 1
    }

    mutating func receive(_ iq: RF.IQBuffer) -> RF.ReceivedBlock {
      var mf = RF.IQBuffer()
      filter.process(iq, into: &mf)
      mf.scale(by: 1 / Float(sps).squareRoot())
      var out = RF.ReceivedBlock()
      // The first sample at or after the pulse-pair delay that falls on a symbol instant.
      var n = max(0, delay - counter)
      let phase = (counter + n - delay) % sps
      if phase != 0 { n += sps - phase }
      while n < mf.count {
        out.symbols.append(mf.i[n], mf.q[n])
        n += sps
      }
      counter += mf.count
      out.bits = constellation.demap(out.symbols)
      return out
    }
  }

  fileprivate struct FSKRX: Sendable {
    let sps: Int
    let delay: Int
    var counter = 0
    var previousI: Float = 1
    var previousQ: Float = 0
    var accumulator = 0.0
    var centreI: Float = 0
    var centreQ: Float = 0

    init(_ settings: RF.FSKSettings) {
      sps = settings.samplesPerSymbol
      delay = RF.FSKModulator(settings).filterDelay
    }

    mutating func receive(_ iq: RF.IQBuffer) -> RF.ReceivedBlock {
      var out = RF.ReceivedBlock()
      for n in 0..<iq.count {
        let x = iq.i[n]
        let y = iq.q[n]
        let re = Double(x * previousI + y * previousQ)
        let im = Double(y * previousI - x * previousQ)
        previousI = x
        previousQ = y
        let g = counter + n - delay
        guard g >= 0 else { continue }
        accumulator += atan2(im, re)
        if g % sps == sps / 2 {
          centreI = x
          centreQ = y
        }
        if g % sps == sps - 1 {
          out.bits.append(accumulator >= 0 ? 1 : 0)
          out.symbols.append(centreI, centreQ)
          accumulator = 0
        }
      }
      counter += iq.count
      return out
    }
  }

  fileprivate struct DSSSRX: Sendable {
    let constellation: RF.Constellation
    let spreader: RF.DSSSSpreader
    var carry = RF.IQBuffer()

    init(modulation: RF.DigitalModulation, chips: Int, spc: Int) {
      constellation = RF.Constellation(modulation)
      spreader = RF.Receiver.oversampledSpreader(chips: chips, spc: spc)
    }

    mutating func receive(_ iq: RF.IQBuffer) -> RF.ReceivedBlock {
      let l = spreader.code.length
      var input = iq
      if !carry.isEmpty {
        input = carry
        input.append(iq)
      }
      let whole = input.count / l * l
      var out = RF.ReceivedBlock()
      out.symbols = spreader.despread(whole == input.count ? input : input.slice(0..<whole))
      out.bits = constellation.demap(out.symbols)
      carry = whole < input.count ? input.slice(whole..<input.count) : RF.IQBuffer()
      return out
    }
  }

  fileprivate struct OFDMRX: Sendable {
    let constellation: RF.Constellation
    let demodulator: RF.OFDMDemodulator?
    let frameSamples: Int
    let frameSymbols: Int
    var tracker: RF.PilotTracker?
    var carry = RF.IQBuffer()

    init(modulation: RF.DigitalModulation, config: RF.OFDMConfig, frameSymbols: Int, averaging: Double, tracksPhase: Bool) {
      constellation = RF.Constellation(modulation)
      demodulator = RF.OFDMDemodulator(config: config)
      self.frameSymbols = frameSymbols
      frameSamples = frameSymbols * config.symbolLength
      tracker = averaging > 1 ? RF.PilotTracker(alpha: Float(1 / averaging), tracksCommonPhase: tracksPhase) : nil
    }

    /// Demodulates every whole frame available (frames are what `Transmitter.modulate` produced).
    mutating func receive(_ iq: RF.IQBuffer) -> RF.ReceivedBlock {
      var out = RF.ReceivedBlock()
      guard let demodulator, frameSamples > 0 else { return out }
      var input = iq
      if !carry.isEmpty {
        input = carry
        input.append(iq)
      }
      var start = 0
      while start + frameSamples <= input.count {
        let frame = start == 0 && input.count == frameSamples ? input : input.slice(start..<(start + frameSamples))
        let r = demodulator.demodulate(frame, symbols: frameSymbols, tracker: &tracker)
        out.symbols.append(r.data)
        out.channelEstimate = r.channelEstimate
        start += frameSamples
      }
      out.bits = constellation.demap(out.symbols)
      carry = start < input.count ? input.slice(start..<input.count) : RF.IQBuffer()
      return out
    }
  }

  fileprivate struct AnalogRX: Sendable {
    var demodulator: RF.AnalogDemodulator
    var down: RF.DSP.Decimator

    init(_ settings: RF.WaveformSettings) {
      demodulator = RF.AnalogDemodulator(RF.Receiver.analogSettings(settings))
      down = RF.DSP.Decimator(factor: settings.analogOversampling)
    }

    mutating func demodulate(_ iq: RF.IQBuffer) -> [Float] { down.process(demodulator.demodulate(iq)) }
  }
}
