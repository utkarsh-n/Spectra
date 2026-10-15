import Foundation
import simd

// Modulator and Demodulator: the RF engine's transmitter and receiver halves as separate
// nodes (API-RF "Separate stages"). Complex baseband in and out; the carrier is a label.
// Voice on a digital mode is 8 kHz, 8-bit µ-law (64 kb/s, gyre-integration §4.4).

/// G.711-style µ-law (µ = 255) with an 8 kHz rate change, for voice over digital modes.
nonisolated enum MuLaw {
  static let mu = 255.0
  static let voiceRate = 8000.0
  static let factor = 6  // 48 kHz ↔ 8 kHz

  /// One sample in −1…1 → an 8-bit code (0…255).
  static func encode(_ x: Float) -> UInt8 {
    let v = min(1, max(-1, Double(x.isFinite ? x : 0)))
    let y = (v < 0 ? -1.0 : 1.0) * log(1 + mu * abs(v)) / log(1 + mu)
    return UInt8(min(255, max(0, ((y + 1) / 2 * 255).rounded())))
  }

  /// An 8-bit code → a sample in −1…1.
  static func decode(_ code: UInt8) -> Float {
    let y = Double(code) / 255 * 2 - 1
    return Float((y < 0 ? -1.0 : 1.0) * (pow(1 + mu, abs(y)) - 1) / mu)
  }

  /// Codes → bits, MSB first.
  static func bits(_ codes: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(codes.count * 8)
    for c in codes {
      for b in (0..<8).reversed() { out.append((c >> UInt8(b)) & 1) }
    }
    return out
  }
}

/// The Modulator's modes as RF waveforms.
nonisolated enum ModemModes {
  /// Wi-Fi 6 (HE20) OFDM numerology from the systems catalogue, scaled as the Radio tab runs it.
  static let wifi6Config: RF.OFDMConfig = {
    if case .ofdm(_, let c)? = RF.SystemsCatalog.system(id: "wifi-ax")?.waveform { return c }
    return .scaled(
      name: "HE20 (scaled)", fftSize: 256, usedFraction: 242.0 / 256, pilotSpacing: 30, cpFraction: 0.0625,
      subcarrierSpacing: RF.Numerology.WiFi.heSubcarrierSpacing, estimation: .preamble)
  }()

  /// The waveform for a digital mode key, nil for analog modes.
  static func waveform(mode: String, symbolRate: Double, ofdmOrder: String) -> RF.WaveformSettings? {
    let rs = symbolRate.isFinite ? min(max(symbolRate, 300), 1e6) : 32_000
    let rrc = RF.PulseShape.rootRaisedCosine(rolloff: 0.35)
    let w: RF.Waveform
    switch mode {
    case "ask": w = .linear(modulation: .ook, symbolRate: rs, pulse: rrc)
    case "fsk": w = .fsk(index: 1, bt: nil, symbolRate: rs)
    case "bpsk", "qpsk", "qam16", "qam64", "qam256", "qam1024":
      guard let m = RF.DigitalModulation(rawValue: mode) else { return nil }
      w = .linear(modulation: m, symbolRate: rs, pulse: rrc)
    case "ofdm":
      w = .ofdm(modulation: RF.DigitalModulation(rawValue: ofdmOrder) ?? .qam1024, config: wifi6Config)
    default: return nil
    }
    return RF.WaveformSettings(waveform: w)
  }

  static func analogKind(_ mode: String) -> RF.AnalogModulation {
    switch mode {
    case "fm": .fm
    case "pm": .pm
    default: .am
    }
  }

  /// Bits per decision the transmitter takes at a time (whole OFDM frames, whole symbols).
  static func granule(_ s: RF.WaveformSettings) -> Int {
    if case .ofdm = s.waveform { return max(1, s.framePlan.bits) }
    if case .fsk = s.waveform { return 1 }
    return max(1, s.dataModulation?.bitsPerSymbol ?? 1)
  }
}

// MARK: - Modulator

nonisolated struct ModulatorProcessor: NodeProcessor {
  var scheme: ModemScheme?
  var tx: RF.Transmitter?
  var analog: RF.AnalogModulator?
  var fifo: [UInt8] = []
  var voiceDecimator = RF.DSP.Decimator(factor: MuLaw.factor)

  mutating func process(_ ctx: inout NodeContext) {
    let mode = ctx.string("mode")
    let carrier = carrierHz(ctx)
    if NodeCatalog.analogModes.contains(mode) {
      analogStep(&ctx, mode: mode, carrier: carrier)
    } else {
      digitalStep(&ctx, mode: mode, carrier: carrier)
    }
  }

  private func carrierHz(_ ctx: NodeContext) -> Double {
    if let w = ctx.input("carrier")?.payload.em { return w.frequency }
    if let f = ctx.control("carrier"), f > 0 { return f }
    return ctx.number("carrier")
  }

  private mutating func analogStep(_ ctx: inout NodeContext, mode: String, carrier: Double) {
    guard let msg = ctx.audio("message") else {
      if ctx.isConnected("message") {
        ctx.warn("AM, FM and PM carry audio. Pick a digital mode for bits.")
      } else {
        ctx.wait("Cable a message in.")
      }
      return
    }
    guard !msg.isIrregular, msg.sampleRate > 0, msg.count > 0 else {
      ctx.warn("This stream has no steady rate to modulate.")
      return
    }
    let depth = ctx.number("depth")
    let deviation = ctx.number("deviation")
    if mode != "pm", abs(msg.sampleRate - NodeCatalog.audioRate) < 1 {
      // The RF engine's analog transmitter: 48 kHz audio, oversampled for wide FM.
      let ws = RF.WaveformSettings(
        waveform: mode == "am" ? .analogAM(depth: depth) : .analogFM(deviation: deviation, audioBandwidth: 4000))
      let next = ModemScheme.waveform(ws, mode: mode, payload: .data)
      if next != scheme {
        scheme = next
        tx = RF.Transmitter(ws)
        analog = nil
      }
      guard var t = tx else { return }
      let iq = t.modulate(audio: msg.samples)
      tx = t
      ctx.emit(
        "signal",
        .iq(
          IQBlock(
            iq: iq, sampleRate: ws.sampleRate, startTime: msg.startTime, carrierHz: carrier,
            bandwidth: ws.occupiedBandwidth, scheme: next)))
      return
    }
    // Native-rate analog (PM, or a sensor-rate message): deviation must stay below fs/2.
    var s = RF.AnalogSettings(kind: ModemModes.analogKind(mode), sampleRate: msg.sampleRate)
    s.amDepth = depth
    s.fmDeviation = min(deviation, 0.45 * msg.sampleRate)
    if mode == "fm", deviation > s.fmDeviation {
      ctx.note("Deviation held to 0.45 × the \(SpinFIDProcessor.hz(msg.sampleRate)) rate.")
    }
    let next = ModemScheme.analog(s, mode: mode)
    if next != scheme {
      scheme = next
      analog = RF.AnalogModulator(s)
      tx = nil
    }
    guard var m = analog else { return }
    let iq = m.modulate(msg.samples)
    analog = m
    ctx.emit(
      "signal",
      .iq(IQBlock(iq: iq, sampleRate: s.sampleRate, startTime: msg.startTime, carrierHz: carrier, bandwidth: 0, scheme: next)))
  }

  private mutating func digitalStep(_ ctx: inout NodeContext, mode: String, carrier: Double) {
    guard let ws = ModemModes.waveform(mode: mode, symbolRate: ctx.number("symbolRate"), ofdmOrder: ctx.string("order"))
    else {
      ctx.warn("Unknown mode.")
      return
    }
    var payload = ModemScheme.Payload.data
    var start = ctx.world.time
    if let msg = ctx.audio("message") {
      payload = .voice
      start = msg.startTime
      guard abs(msg.sampleRate - NodeCatalog.audioRate) < 1 else {
        ctx.warn("Voice on a digital mode needs 48 kHz audio.")
        return
      }
      let narrow = voiceDecimator.process(msg.samples)
      fifo.append(contentsOf: MuLaw.bits(narrow.map(MuLaw.encode)))
    } else if let b = ctx.input("message")?.payload.bits {
      fifo.append(contentsOf: b.bits)
    } else if !ctx.isConnected("message") {
      ctx.wait("Cable bits or audio in.")
      return
    }
    let next = ModemScheme.waveform(ws, mode: mode, payload: payload)
    if next != scheme {
      scheme = next
      tx = RF.Transmitter(ws)
      analog = nil
      fifo.removeAll()
      return
    }
    let granule = ModemModes.granule(ws)
    // Keep at most a few frames queued: a slow sink must not grow the queue forever.
    let cap = max(granule * 4, 65_536)
    if fifo.count > cap { fifo.removeFirst(fifo.count - cap) }
    let isOFDM: Bool = {
      if case .ofdm = ws.waveform { return true }
      return false
    }()
    // One OFDM frame per step keeps a step short; keyed and QAM modes take every whole symbol.
    let chunk = isOFDM ? min(fifo.count / granule, 1) * granule : (fifo.count / granule) * granule
    guard chunk > 0, var t = tx else {
      ctx.wait("Collecting bits: \(fifo.count) of \(granule).")
      return
    }
    let bits = Array(fifo.prefix(chunk))
    fifo.removeFirst(chunk)
    var samples = RF.IQBuffer()
    if isOFDM {
      var k = 0
      while k < bits.count {
        samples.append(t.modulate(bits: Array(bits[k..<(k + granule)])).samples)
        k += granule
      }
    } else {
      samples = t.modulate(bits: bits).samples
    }
    tx = t
    let m = ws.dataModulation
    ctx.emit(
      "signal",
      .iq(
        IQBlock(
          iq: samples, sampleRate: ws.sampleRate, startTime: start, carrierHz: carrier, bandwidth: ws.occupiedBandwidth,
          ideal: m.map { RF.Constellation($0).points.map { SIMD2(Float($0.re), Float($0.im)) } } ?? [], modulation: m,
          scheme: next, sentBits: bits)))
  }
}

// MARK: - Demodulator

nonisolated struct DemodulatorProcessor: NodeProcessor {
  var scheme: ModemScheme?
  var rx: RF.Receiver?
  var analog: RF.AnalogDemodulator?
  var decimator: RF.DSP.Decimator?
  var voiceInterpolator = RF.DSP.Interpolator(factor: MuLaw.factor)
  /// Sent bits not yet matched with received ones.
  var pending: [UInt8] = []
  /// Bit errors and bits over a sliding window.
  var window: [(bits: Int, errors: Int)] = []
  /// Received bits not yet a whole µ-law code or text byte.
  var byteCarry: [UInt8] = []
  var text = ""
  var evm = Double.nan
  /// Post-detection audio low-pass (voice band), as a real AM/FM receiver has.
  var audioFilter: RF.DSP.FIRFilter?
  var audioFilterRate = 0.0
  static let voiceBandEdge = 4500.0

  /// Low-passes recovered audio to the voice band (linear phase, 127 taps): without it the FM
  /// discriminator's noise, which rises with frequency up to fs/2, would swamp the voice.
  mutating func voiceBand(_ x: [Float], rate: Double) -> [Float] {
    guard rate >= 4 * Self.voiceBandEdge else { return x }
    if audioFilter == nil || audioFilterRate != rate {
      audioFilter = RF.DSP.FIRFilter(taps: RF.DSP.firTaps(.lowpass, cutoff: Self.voiceBandEdge / rate, taps: 127))
      audioFilterRate = rate
    }
    return audioFilter?.process(x) ?? x
  }

  var ber: Double? {
    let n = window.reduce(0) { $0 + $1.bits }
    guard n > 0 else { return nil }
    return Double(window.reduce(0) { $0 + $1.errors }) / Double(n)
  }

  mutating func process(_ ctx: inout NodeContext) {
    guard let sig = ctx.iq("signal") else {
      ctx.wait("Cable a modulated signal in.")
      return
    }
    guard let next = resolveScheme(ctx, sig) else {
      ctx.warn("This signal carries no modulation to undo. Pick a mode.")
      return
    }
    if next != scheme {
      scheme = next
      rebuild(next)
    }
    switch next {
    case .analog(let s, _):
      guard var d = analog else { return }
      let audio = voiceBand(d.demodulate(sig.iq), rate: s.sampleRate)
      analog = d
      ctx.emit("audio", .audio(RealBlock(samples: audio, sampleRate: s.sampleRate, startTime: sig.startTime)))
    case .waveform(let ws, let mode, let payload):
      guard var r = rx else { return }
      if abs(sig.sampleRate - ws.sampleRate) > 1e-6 * ws.sampleRate {
        ctx.warn("The signal's rate does not match this mode. Try Match the signal.")
      }
      let got = r.receive(sig.iq)
      rx = r
      if let audio = got.audio {
        let filtered = voiceBand(audio, rate: RF.WaveformSettings.audioRate)
        ctx.emit("audio", .audio(RealBlock(samples: filtered, sampleRate: RF.WaveformSettings.audioRate, startTime: sig.startTime)))
        return
      }
      digitalOutputs(&ctx, sig: sig, got: got, ws: ws, mode: mode, payload: payload)
    }
  }

  private func resolveScheme(_ ctx: NodeContext, _ sig: IQBlock) -> ModemScheme? {
    let mode = ctx.string("mode")
    if mode == "auto" || mode.isEmpty { return sig.scheme }
    if NodeCatalog.analogModes.contains(mode) {
      if mode != "pm", abs(sig.sampleRate - NodeCatalog.audioRate * Double(oversampling(ctx, mode))) < 1 {
        return .waveform(
          RF.WaveformSettings(
            waveform: mode == "am"
              ? .analogAM(depth: ctx.number("depth"))
              : .analogFM(deviation: ctx.number("deviation"), audioBandwidth: 4000)),
          mode: mode, payload: .data)
      }
      var s = RF.AnalogSettings(kind: ModemModes.analogKind(mode), sampleRate: sig.sampleRate)
      s.amDepth = ctx.number("depth")
      s.fmDeviation = min(ctx.number("deviation"), 0.45 * sig.sampleRate)
      return .analog(s, mode: mode)
    }
    guard let ws = ModemModes.waveform(mode: mode, symbolRate: ctx.number("symbolRate"), ofdmOrder: ctx.string("order"))
    else { return nil }
    return .waveform(ws, mode: mode, payload: ctx.string("payload") == "voice" ? .voice : .data)
  }

  private func oversampling(_ ctx: NodeContext, _ mode: String) -> Int {
    let ws = RF.WaveformSettings(
      waveform: mode == "am"
        ? .analogAM(depth: ctx.number("depth")) : .analogFM(deviation: ctx.number("deviation"), audioBandwidth: 4000))
    return ws.analogOversampling
  }

  private mutating func rebuild(_ s: ModemScheme) {
    rx = nil
    analog = nil
    pending.removeAll()
    window.removeAll()
    byteCarry.removeAll()
    text = ""
    evm = .nan
    audioFilter = nil
    voiceInterpolator = RF.DSP.Interpolator(factor: MuLaw.factor)
    switch s {
    case .analog(let a, _): analog = RF.AnalogDemodulator(a)
    case .waveform(let ws, _, _): rx = RF.Receiver(ws)
    }
  }

  private mutating func digitalOutputs(
    _ ctx: inout NodeContext, sig: IQBlock, got: RF.ReceivedBlock, ws: RF.WaveformSettings, mode: String,
    payload: ModemScheme.Payload
  ) {
    let m = ws.dataModulation
    // Bit errors against what the Modulator sent (the receiver keeps transmit order).
    pending.append(contentsOf: sig.sentBits)
    if pending.count > 1 << 20 { pending.removeFirst(pending.count - (1 << 20)) }
    let n = min(pending.count, got.bits.count)
    if n > 0 {
      let errors = RF.Bits.errors(Array(pending.prefix(n)), Array(got.bits.prefix(n)))
      pending.removeFirst(n)
      window.append((n, errors))
      var total = window.reduce(0) { $0 + $1.bits }
      while total > 200_000, window.count > 1 {
        total -= window.removeFirst().bits
      }
    }
    // Decision-directed EVM of the symbols.
    if got.symbols.count > 0, let m {
      var decided = RF.IQBuffer()
      RF.Constellation(m).decisions(got.symbols, into: &decided)
      let e = RF.EVMResult.measure(received: got.symbols, reference: decided).percent
      evm = evm.isFinite ? 0.8 * evm + 0.2 * e : e
      let ideal = RF.Constellation(m).points.map { SIMD2(Float($0.re), Float($0.im)) }
      ctx.emit(
        "symbols",
        .iq(
          IQBlock(
            iq: got.symbols, sampleRate: ws.symbolRate, startTime: sig.startTime, carrierHz: sig.carrierHz,
            isSymbols: true, ideal: ideal, modulation: m)))
    } else if got.symbols.count > 0 {
      ctx.emit(
        "symbols",
        .iq(
          IQBlock(
            iq: got.symbols, sampleRate: ws.symbolRate, startTime: sig.startTime, carrierHz: sig.carrierHz,
            isSymbols: true)))
    }
    if evm.isFinite { ctx.emit("evm", control: evm) }
    if let ber { ctx.emit("ber", control: ber) }
    guard !got.bits.isEmpty else { return }
    byteCarry.append(contentsOf: got.bits)
    let whole = (byteCarry.count / 8) * 8
    let bytes = Array(byteCarry.prefix(whole))
    byteCarry.removeFirst(whole)
    switch payload {
    case .voice:
      var codes = [UInt8]()
      codes.reserveCapacity(bytes.count / 8)
      var k = 0
      while k + 8 <= bytes.count {
        var v: UInt8 = 0
        for j in 0..<8 { v = (v << 1) | (bytes[k + j] & 1) }
        codes.append(v)
        k += 8
      }
      let narrow = codes.map(MuLaw.decode)
      let wide = voiceInterpolator.process(narrow)
      ctx.emit("audio", .audio(RealBlock(samples: wide, sampleRate: NodeCatalog.audioRate, startTime: sig.startTime)))
      ctx.emit("bits", .bits(BitsBlock(bits: got.bits, text: nil)))
    case .data:
      let decoded = RF.Bits.toText(bytes)
      text = String((text + decoded).suffix(160))
      ctx.emit("bits", .bits(BitsBlock(bits: got.bits, text: text)))
    }
    _ = mode
  }
}
