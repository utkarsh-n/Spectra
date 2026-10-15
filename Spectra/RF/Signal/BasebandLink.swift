import Foundation

nonisolated extension RF {
  /// Settings of the Fourier page's end-to-end baseband simulation.
  struct BasebandLinkConfig: Hashable, Codable, Sendable {
    /// Message source for digital waveforms.
    enum Message: Hashable, Codable, Sendable {
      /// Seeded random bits.
      case random
      /// UTF-8 bits of a text, repeated.
      case text(String)
    }

    var waveform: Waveform
    /// Replaces the data modulation of linear, DSSS and OFDM waveforms.
    var modulation: DigitalModulation?
    /// Digital waveforms: E_s/N₀ per data symbol (dB). Analog and tone: carrier-to-noise ratio
    /// in the channel bandwidth (Carson for FM, 2W for AM). nil = noiseless.
    var snrDB: Double?
    /// RMS delay spread of the exponential multipath profile, s.
    var delaySpread: Double = 0
    /// Maximum Doppler f_m, Hz (applies to Rayleigh/Rician taps).
    var dopplerHz: Double = 0
    var fading: FadingKind = .none
    /// Carrier frequency offset, Hz.
    var frequencyOffsetHz: Double = 0
    /// Oversampling of linear and FSK waveforms.
    var samplesPerSymbol: Int = 8
    /// Oversampling of DSSS chips (rectangular chips).
    var samplesPerChip: Int = 2
    /// Approximate samples per frame (whole symbols / OFDM symbols are used).
    var targetSamples: Int = 4096
    var message: Message = .random
    var seed: UInt64 = 1

    init(waveform: Waveform) { self.waveform = waveform }

    /// A configuration for a catalog system.
    init(system: RadioSystem) { self.init(waveform: system.waveform) }

    /// The sampling/framing part shared with `Transmitter` and `Receiver`.
    var settings: WaveformSettings {
      var s = WaveformSettings(waveform: waveform, modulation: modulation)
      s.samplesPerSymbol = samplesPerSymbol
      s.samplesPerChip = samplesPerChip
      s.targetSamples = targetSamples
      return s
    }
  }

  /// One simulated frame: what the transmitter sent, what the channel delivered, and what the
  /// receiver made of it.
  struct BasebandFrame: Sendable {
    /// Real-world sample rate the samples stand for, Hz.
    var sampleRate: Double
    /// Symbol rate of the data symbols, Hz (0 for analog and tone).
    var symbolRate: Double
    /// Transmitted complex baseband (unit mean power, AM: carrier power 1).
    var tx: IQBuffer
    /// Channel output (multipath, fading, CFO, noise).
    var rx: IQBuffer
    /// Receiver decision-point samples — the constellation (matched-filtered, despread, or
    /// OFDM-equalized; FSK: samples at symbol centres).
    var received: IQBuffer
    /// The transmitted symbols aligned with `received`.
    var ideal: IQBuffer
    /// Bits sent and hard-decision bits received for the symbols in `received` (aligned).
    var sentBits: [UInt8]
    var receivedBits: [UInt8]
    /// RMS EVM of `received` against `ideal` (linear, DSSS, OFDM).
    var evm: EVMResult?
    /// AWGN theory for the bit error rate at the configured E_s/N₀ (nil without a formula).
    var berTheory: Double?
    /// Demodulated audio at 48 kHz (analog waveforms).
    var audio: [Float]?
    /// OFDM least-squares channel estimate on the used subcarriers of the last symbol.
    var channelEstimate: IQBuffer?

    /// Bit errors in this frame.
    var bitErrors: Int { RF.Bits.errors(sentBits, receivedBits) }
    /// Bit error ratio of this frame (0 when no bits).
    var ber: Double { sentBits.isEmpty ? 0 : Double(bitErrors) / Double(min(sentBits.count, receivedBits.count)) }
  }

  /// The stateful end-to-end simulator of the Fourier page: `Transmitter` → `ChannelSimulator`
  /// → `Receiver`, with the sent symbols queued so every received symbol is compared with the
  /// one that produced it. Call `next(audio:)` once per frame; filter histories, the channel's
  /// fading and delay line, oscillator phases and the symbol pipeline continue across frames, so
  /// consecutive frames form one continuous signal.
  ///
  /// Cost: a 4096-sample frame (generate, channel, receive) takes about 0.2–0.4 ms on Apple
  /// silicon (Tools/check-rf.sh times it); run it off the main actor if you like.
  struct BasebandLink: Sendable {
    let config: BasebandLinkConfig
    let settings: WaveformSettings
    /// Real-world sample rate of the simulated samples, Hz.
    let sampleRate: Double
    /// Data modulation in use (nil for analog, FSK and tone).
    let modulation: DigitalModulation?
    /// Analog: audio rate is 48 kHz; the IQ rate is 48 kHz × this factor.
    let analogOversampling: Int

    private var transmitter: Transmitter
    private var receiver: Receiver
    private var channel: ChannelSimulator
    private var bits: BitSource
    private var queue: SymbolQueue
    private var tonePhase = 0.0

    /// Audio rate of analog waveforms.
    static let audioRate = WaveformSettings.audioRate

    init(_ config: BasebandLinkConfig) {
      self.config = config
      let settings = config.settings
      self.settings = settings
      sampleRate = settings.sampleRate
      modulation = settings.dataModulation
      analogOversampling = settings.analogOversampling
      bits = BitSource(config.message, seed: config.seed)
      queue = SymbolQueue(bitsPerSymbol: settings.dataModulation?.bitsPerSymbol ?? 1)
      transmitter = Transmitter(settings)
      // Channel estimates average over about a quarter of the coherence time 0.423/f_m (at most
      // 16 updates; pilots update every OFDM symbol, a preamble once per frame). Common-phase
      // tracking is switched on when there is something to track (CFO or Doppler), so an AWGN
      // run lands on the theory curve.
      var averaging = 16.0
      var tracksPhase = false
      if case .ofdm(_, let c) = config.waveform {
        let symbolTime = Double(c.symbolLength) / c.sampleRate
        let updateTime = c.estimation == .preamble ? Double(settings.framePlan.symbols) * symbolTime : symbolTime
        if config.fading != .none, config.dopplerHz > 0 {
          averaging = min(16, max(1, RF.Fading.coherenceTime(maxDoppler: config.dopplerHz) / updateTime / 4))
        }
        tracksPhase = config.frequencyOffsetHz != 0 || (config.fading != .none && config.dopplerHz > 0)
      }
      receiver = Receiver(settings, estimateAveraging: averaging, tracksCommonPhase: tracksPhase)
      var channelConfig = ChannelConfig(
        snrDB: config.snrDB.map { settings.perSampleSNR($0) }, delaySpread: config.delaySpread, dopplerHz: config.dopplerHz,
        fading: config.fading, frequencyOffsetHz: config.frequencyOffsetHz, seed: config.seed &+ 0x5EED)
      channelConfig.measureSignalPower = false
      channel = ChannelSimulator(config: channelConfig, sampleRate: settings.sampleRate)
    }

    /// Symbol rate of the digital data, Hz.
    var symbolRate: Double { settings.symbolRate }

    /// Occupied bandwidth of the waveform, Hz (for the channel mask on the spectrum).
    var occupiedBandwidth: Double { settings.occupiedBandwidth }

    /// AWGN bit-error theory at the configured E_s/N₀.
    var berTheory: Double? {
      guard let m = modulation, let es = config.snrDB else { return nil }
      return RF.ErrorRates.ber(m, ebN0DB: RF.Noise.ebN0DB(esN0DB: es, bitsPerSymbol: m.bitsPerSymbol))
    }

    /// Simulates the next frame. `audio` (48 kHz, ±1) drives analog waveforms; when nil they
    /// transmit a 1 kHz test tone at 0.8 of full scale.
    mutating func next(audio: [Float]? = nil) -> BasebandFrame {
      var frame = BasebandFrame(
        sampleRate: sampleRate, symbolRate: symbolRate, tx: IQBuffer(), rx: IQBuffer(), received: IQBuffer(), ideal: IQBuffer(),
        sentBits: [], receivedBits: [], evm: nil, berTheory: berTheory, audio: nil, channelEstimate: nil)
      let plan = settings.framePlan
      switch config.waveform {
      case .tone:
        frame.tx = transmitter.carrier(count: plan.samples)
        frame.rx = channel.process(frame.tx)
        frame.berTheory = nil
      case .chirp:
        frame.tx = transmitter.sweep(count: plan.samples)
        frame.rx = channel.process(frame.tx)
        frame.berTheory = nil
      case .analogAM, .analogFM:
        let input = audio ?? testTone(count: max(1, plan.samples / analogOversampling))
        frame.tx = transmitter.modulate(audio: input)
        frame.rx = channel.process(frame.tx)
        frame.audio = receiver.receive(frame.rx).audio
        frame.berTheory = nil
      default:
        let b = bits.next(plan.bits)
        let (samples, symbols) = transmitter.modulate(bits: b)
        queue.push(symbols, bits: b)
        frame.tx = samples
        frame.rx = channel.process(samples)
        let block = receiver.receive(frame.rx)
        let n = min(block.symbols.count, queue.count)
        for _ in 0..<n { queue.pop(into: &frame) }
        // The receiver runs a fixed latency behind; never let the backlog grow without bound
        // (a waveform the receiver cannot decode would otherwise leak a frame per call).
        queue.trim(keeping: 4 * max(plan.bits, 1) + 4096)
        frame.received = n == block.symbols.count ? block.symbols : block.symbols.slice(0..<n)
        frame.receivedBits = Array(block.bits.prefix(n * (modulation?.bitsPerSymbol ?? 1)))
        frame.channelEstimate = block.channelEstimate
        if case .fsk = config.waveform {
          // FSK has no constellation: `received` holds the IQ at symbol centres, `ideal` stays empty.
          frame.ideal = IQBuffer()
          frame.berTheory = nil
        }
      }
      if modulation != nil, !frame.received.isEmpty, frame.ideal.count == frame.received.count {
        frame.evm = EVMResult.measure(received: frame.received, reference: frame.ideal)
      }
      return frame
    }

    private mutating func testTone(count: Int) -> [Float] {
      var out = [Float](repeating: 0, count: count)
      let step = 2 * Double.pi * 1000 / BasebandLink.audioRate
      for k in 0..<count {
        out[k] = Float(0.8 * sin(tonePhase))
        tonePhase += step
      }
      tonePhase = tonePhase.truncatingRemainder(dividingBy: 2 * Double.pi)
      return out
    }
  }
}

// MARK: - Message and alignment

nonisolated extension RF.BasebandLink {
  /// Bits from the configured message.
  fileprivate struct BitSource: Sendable {
    var rng: RF.SeededRandom
    let text: [UInt8]
    var position = 0

    init(_ message: RF.BasebandLinkConfig.Message, seed: UInt64) {
      rng = RF.SeededRandom(seed: seed)
      if case .text(let s) = message, !s.isEmpty { text = RF.Bits.fromText(s) } else { text = [] }
    }

    mutating func next(_ count: Int) -> [UInt8] {
      if text.isEmpty { return rng.bits(count) }
      var out = [UInt8](repeating: 0, count: count)
      for k in 0..<count {
        out[k] = text[position]
        position = (position + 1) % text.count
      }
      return out
    }
  }

  /// FIFO of transmitted symbols and their bits awaiting the receiver.
  fileprivate struct SymbolQueue: Sendable {
    var i: [Float] = []
    var q: [Float] = []
    var bits: [UInt8] = []
    var head = 0
    let bitsPerSymbol: Int

    init(bitsPerSymbol: Int) { self.bitsPerSymbol = bitsPerSymbol }

    var count: Int { i.count - head }

    mutating func push(_ symbols: RF.IQBuffer, bits b: [UInt8]) {
      compact()
      i.append(contentsOf: symbols.i)
      q.append(contentsOf: symbols.q)
      bits.append(contentsOf: b)
      // Pad bits for a trailing partial symbol so indexing stays aligned.
      let missing = symbols.count * bitsPerSymbol - b.count
      if missing > 0 { bits.append(contentsOf: repeatElement(0, count: missing)) }
    }

    /// Pops the oldest symbol into the frame.
    mutating func pop(into frame: inout RF.BasebandFrame) {
      guard head < i.count else { return }
      frame.ideal.append(i[head], q[head])
      let k = bitsPerSymbol
      frame.sentBits.append(contentsOf: bits[(head * k)..<((head + 1) * k)])
      head += 1
    }

    /// Drops the oldest symbols beyond `keeping`.
    mutating func trim(keeping limit: Int) {
      let excess = count - limit
      guard excess > 0 else { return }
      head += excess
      compact()
    }

    private mutating func compact() {
      guard head > 4096 else { return }
      i.removeFirst(head)
      q.removeFirst(head)
      bits.removeFirst(head * bitsPerSymbol)
      head = 0
    }
  }
}
