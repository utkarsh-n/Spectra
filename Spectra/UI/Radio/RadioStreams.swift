import Foundation

/// Feeds the Radio tab's simulated streams on the scope bus (all **MODEL**):
///
/// - `radio.i`, `radio.q`: the received complex baseband of the selected system, played out
///   κ-slowed at 2.4 kHz so a scope can follow the symbol trajectory (the real sample rate is
///   MHz–GHz; one simulated sample, or every second one for oversampled single-carrier
///   waveforms, per 1/2400 s);
/// - `radio.audio`: for AM/FM, the demodulated 1 kHz test tone in real time at 48 kHz (the
///   Fourier page's push-to-talk voice takes this stream over while it runs).
///
/// A value type driven from one detached task; it owns its own `RF.BasebandLink`s, so it never
/// shares simulator state with the Fourier page.
nonisolated struct RadioStreamProducer: Sendable {
  struct Streams: Sendable {
    let i: SignalStream
    let q: SignalStream
    let audio: SignalStream
  }

  /// Rate of the κ-slowed I/Q streams, Hz.
  static let iqRate = 2400.0
  static let audioRate = RF.BasebandLink.audioRate

  let streams: Streams
  let config: RF.BasebandLinkConfig
  /// Simulated samples advanced per published I/Q sample.
  let stride: Int
  private var link: RF.BasebandLink
  private var audioLink: RF.BasebandLink?
  private var pending = RF.IQBuffer()
  private var cursor = 0
  private var nextIQ: Double?
  private var nextAudio: Double?
  private var tonePhase = 0.0

  init(config: RF.BasebandLinkConfig, streams: Streams) {
    self.config = config
    self.streams = streams
    link = RF.BasebandLink(config)
    switch config.waveform {
    case .linear, .fsk: stride = max(1, config.settings.sps / 4)
    default: stride = 1
    }
    audioLink = RadioModel.isAnalog(config.waveform) ? RF.BasebandLink(config) : nil
  }

  /// Simulated seconds shown per real second on the I/Q streams.
  var slowdown: Double { link.sampleRate / (Double(stride) * Self.iqRate) }

  /// Appends every sample due up to `now` (`SignalClock` time). After a stall it skips ahead
  /// instead of catching up.
  mutating func produce(until now: Double, writeAudio: Bool) {
    produceIQ(until: now)
    if writeAudio, audioLink != nil {
      produceAudio(until: now)
    } else {
      nextAudio = nil
    }
  }

  private mutating func produceIQ(until now: Double) {
    let dt = 1 / Self.iqRate
    var t = nextIQ ?? now
    if now - t > 0.25 { t = now - 0.25 }
    var iv: [Float] = []
    var qv: [Float] = []
    let start = t
    while t <= now, iv.count < 4096 {
      if cursor >= pending.count {
        pending = link.next().rx
        cursor = 0
        if pending.isEmpty { break }
      }
      iv.append(pending.i[cursor])
      qv.append(pending.q[cursor])
      cursor += stride
      t += dt
    }
    nextIQ = t
    guard !iv.isEmpty else { return }
    streams.i.ring.append(contentsOf: iv, start: start, interval: dt)
    streams.q.ring.append(contentsOf: qv, start: start, interval: dt)
  }

  private mutating func produceAudio(until now: Double) {
    guard var a = audioLink else { return }
    let dt = 1 / Self.audioRate
    var t = nextAudio ?? now
    if now - t > 0.2 || t > now + 0.2 { t = now }
    if let last = streams.audio.ring.latest?.time, t <= last { t = last + dt }
    let count = min(Int(((now - t) * Self.audioRate).rounded(.down)), 9600)
    guard count > 0 else {
      nextAudio = t
      return
    }
    // The 1 kHz test tone at 0.8 of full scale (what `BasebandLink` sends without audio).
    var tone = [Float](repeating: 0, count: count)
    let step = 2 * Double.pi * 1000 / Self.audioRate
    for k in 0..<count {
      tone[k] = Float(0.8 * sin(tonePhase))
      tonePhase += step
    }
    tonePhase = tonePhase.truncatingRemainder(dividingBy: 2 * Double.pi)
    let out = a.next(audio: tone).audio ?? []
    audioLink = a
    if !out.isEmpty { streams.audio.ring.append(contentsOf: out, start: t, interval: dt) }
    nextAudio = t + Double(out.isEmpty ? count : out.count) * dt
  }
}
