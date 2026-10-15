import Foundation

/// Digital voice for the Fourier page: microphone audio → 8 kHz → 8-bit µ-law PCM
/// (64 kbit/s) → QPSK at 32 kBd with a root-raised-cosine pulse (β 0.35) → the same channel
/// knobs → matched filter and decisions → µ-law decode → 8 kHz audio for the speaker. Built from
/// the RF engine's separate stages (`Transmitter`, `ChannelSimulator`, `Receiver`), so what you
/// hear is exactly what the bits survived.
nonisolated struct RadioVoiceLink: Sendable {
  static let audioRate = 8000.0
  static let symbolRate = 32_000.0
  static let modulation = RF.DigitalModulation.qpsk
  /// µ for the companding law (G.711's value).
  static let mu = 255.0

  let settings: RF.WaveformSettings
  let snrDB: Double
  private var tx: RF.Transmitter
  private var rx: RF.Receiver
  private var channel: RF.ChannelSimulator
  private var decimator = RF.DSP.Decimator(factor: 6)
  private var sentI: [Float] = []
  private var sentQ: [Float] = []
  private var sentBits: [UInt8] = []
  private var head = 0
  private var leftover: [UInt8] = []

  static var waveform: RF.Waveform {
    .linear(modulation: modulation, symbolRate: symbolRate, pulse: .rootRaisedCosine(rolloff: 0.35))
  }

  init(config: RF.BasebandLinkConfig) {
    var s = RF.WaveformSettings(waveform: Self.waveform)
    s.samplesPerSymbol = 8
    settings = s
    snrDB = config.snrDB ?? 300
    tx = RF.Transmitter(s)
    rx = RF.Receiver(s)
    var c = RF.ChannelConfig(
      snrDB: config.snrDB.map { s.perSampleSNR($0) }, delaySpread: config.delaySpread, dopplerHz: config.dopplerHz,
      fading: config.fading, frequencyOffsetHz: 0, seed: config.seed &+ 0x701CE)
    c.measureSignalPower = false
    channel = RF.ChannelSimulator(config: c, sampleRate: s.sampleRate)
  }

  /// Sends a block of 48 kHz audio (±1) and returns the frame (for the views) and the decoded
  /// 8 kHz audio that came out of the receiver this call.
  mutating func process(_ audio48k: [Float]) -> (frame: RF.BasebandFrame, audio: [Float]) {
    let a8 = decimator.process(audio48k)
    var bits: [UInt8] = []
    bits.reserveCapacity(a8.count * 8)
    for x in a8 {
      let byte = Self.muLawEncode(x)
      for b in (0..<8).reversed() { bits.append((byte >> UInt8(b)) & 1) }
    }
    let (samples, symbols) = tx.modulate(bits: bits)
    sentI.append(contentsOf: symbols.i)
    sentQ.append(contentsOf: symbols.q)
    sentBits.append(contentsOf: bits)
    let received = channel.process(samples)
    let block = rx.receive(received)
    let k = Self.modulation.bitsPerSymbol
    let n = min(block.symbols.count, sentI.count - head)
    var ideal = RF.IQBuffer()
    var sent: [UInt8] = []
    for j in 0..<n {
      ideal.append(sentI[head + j], sentQ[head + j])
      sent.append(contentsOf: sentBits[((head + j) * k)..<((head + j + 1) * k)])
    }
    head += n
    compact()
    let got = Array(block.bits.prefix(n * k))
    let symbolsOut = n == block.symbols.count ? block.symbols : block.symbols.slice(0..<n)
    // Decode whole bytes in order.
    leftover.append(contentsOf: got)
    var audio: [Float] = []
    var j = 0
    while j + 8 <= leftover.count {
      var v: UInt8 = 0
      for b in 0..<8 { v = (v << 1) | (leftover[j + b] & 1) }
      audio.append(Self.muLawDecode(v))
      j += 8
    }
    leftover.removeFirst(j)
    var frame = RF.BasebandFrame(
      sampleRate: settings.sampleRate, symbolRate: Self.symbolRate, tx: samples, rx: received, received: symbolsOut, ideal: ideal,
      sentBits: sent, receivedBits: got, evm: nil,
      berTheory: RF.ErrorRates.ber(Self.modulation, ebN0DB: RF.Noise.ebN0DB(esN0DB: snrDB, bitsPerSymbol: k)), audio: nil,
      channelEstimate: nil)
    if !symbolsOut.isEmpty, ideal.count == symbolsOut.count {
      frame.evm = RF.EVMResult.measure(received: symbolsOut, reference: ideal)
    }
    return (frame, audio)
  }

  private mutating func compact() {
    guard head > 8192 else { return }
    sentI.removeFirst(head)
    sentQ.removeFirst(head)
    sentBits.removeFirst(head * Self.modulation.bitsPerSymbol)
    head = 0
  }

  /// µ-law compression of x ∈ [−1, 1] to 8 bits (code 0 = −1, 255 = +1).
  static func muLawEncode(_ x: Float) -> UInt8 {
    let v = Double(min(max(x.isFinite ? x : 0, -1), 1))
    let y = (v < 0 ? -1.0 : 1.0) * log1p(mu * abs(v)) / log1p(mu)
    return UInt8(min(max(((y + 1) / 2 * 255).rounded(), 0), 255))
  }

  /// Inverse of `muLawEncode`.
  static func muLawDecode(_ code: UInt8) -> Float {
    let y = Double(code) / 255 * 2 - 1
    let x = (y < 0 ? -1.0 : 1.0) * (pow(1 + mu, abs(y)) - 1) / mu
    return Float(x)
  }
}
