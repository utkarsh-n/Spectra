import CoreGraphics
import Foundation
import Observation
import QuartzCore
import simd

/// What the Fourier page draws for one simulated frame (copied out of the engine so the
/// panels can render it without touching simulator state).
struct RadioFourierSnapshot {
  var serial = 0
  var waveformName = ""
  /// Real-world sample rate the samples stand for, Hz.
  var sampleRate = 1.0
  var symbolRate = 0.0
  var occupiedBandwidth = 0.0
  var frameSamples = 0
  /// The I/Q trace (sent or received), as plotted.
  var traceI: [Double] = []
  var traceQ: [Double] = []
  /// Real-world time span of the trace, s.
  var traceDuration = 0.0
  /// Decision points (digital) or the I/Q trajectory (analog, tone, FMCW, FSK).
  var received: [SIMD2<Float>] = []
  var ideal: [SIMD2<Float>] = []
  var constellationRange: Float = 1.5
  var isTrajectory = false
  /// Two-sided spectrum (fftshifted, index count/2 = the carrier), dB relative to its peak,
  /// averaged over frames.
  var spectrum: [Float] = []
  var evm: RF.EVMResult?
  /// Bit error ratio counted since the last change of settings.
  var measuredBER: Double?
  var bitsCounted = 0
  var berTheory: Double?
  var decodedText = ""
  var voice = false
  var modulationName: String?
}

/// The Fourier page's time–frequency pair for one frame: Utkarsh's Wigner–Ville (Phase engine,
/// convention C) and the spectrogram on the same grid, with the M1 check.
nonisolated struct RadioTFResult: Sendable {
  /// rows = time, columns = frequency; Wigner–Ville signed in −1…1, spectrogram in 0…1.
  var wigner: [Float]
  var spectrogram: [Float]
  var rows: Int
  var columns: Int
  /// Frequency span of the columns (Hz, baseband offsets) and time span of the rows (s).
  var frequencyStart: Double
  var frequencyEnd: Double
  var duration: Double
  /// max |Σν W dν − |z|²| / max |z|² over the rows: the time marginal (exact for Wigner–Ville).
  var marginalError: Double
  /// Most negative Wigner value relative to the largest positive one (cross terms; ≈ 0 for a
  /// lone chirp line; below −1 when the cross terms outweigh every auto term).
  var negativeFraction: Double

  static func compute(i: [Float], q: [Float], sampleRate: Double) -> RadioTFResult {
    let z = Phase.Signal.fromIQ(i: i, q: q, sampleRate: sampleRate)
    let wv = Phase.timeFrequency(complex: z, request: .init(mode: .wignerVille, rows: 128, columns: 128))
    let sg = Phase.timeFrequency(complex: z, request: .init(mode: .spectrogram, rows: 128, columns: 128))
    let w = wv.plane.signedUnit()
    let sPeak = sg.plane.values.max() ?? 0
    let s = sg.plane.values.map { sPeak > 0 ? Float(max(0, $0) / sPeak) : 0 }
    let peakIntensity = wv.intensity.max() ?? 0
    let positivePeak = wv.plane.values.max() ?? 0
    let mostNegative = min(0, wv.plane.values.min() ?? 0)
    var err = 0.0
    for (a, b) in zip(wv.timeMarginal, wv.intensity) { err = max(err, abs(a - b)) }
    let axis = wv.plane.columnAxis
    let rows = wv.plane.rowAxis
    return RadioTFResult(
      wigner: w, spectrogram: s, rows: wv.plane.rows, columns: wv.plane.columns, frequencyStart: axis.start,
      frequencyEnd: axis.end, duration: max(rows.end - rows.start, Double(i.count) / max(sampleRate, 1)),
      marginalError: peakIntensity > 0 ? err / peakIntensity : 0,
      negativeFraction: positivePeak > 0 ? mostNegative / positivePeak : 0)
  }
}

/// The Fourier page's frame-rate simulator: one `RF.BasebandLink` (or the digital voice link)
/// advanced once per displayed clock frame while the page is visible, a Welch spectrum with a
/// waterfall, BER counting against theory, the text decoder, push-to-talk voice through
/// `HumSynth`'s PCM ring, and the time–frequency pair computed off the main actor at ~4 Hz.
@Observable @MainActor
final class RadioFourierEngine {
  /// True while the Fourier page is on screen and the app is active.
  private(set) var running = false
  /// Push-to-talk (voice mode): held while the button is pressed.
  private(set) var talking = false
  /// Seconds of received voice waiting to play when the button is released (read it from a
  /// timeline: it changes during frame updates and is not observed).
  @ObservationIgnored private(set) var bufferedSeconds = 0.0
  /// The latest time–frequency pair (updated at ~4 Hz).
  private(set) var tf: RadioTFResult?
  /// True while the voice link owns `radio.audio`.
  private(set) var voiceOwnsAudio = false

  @ObservationIgnored private(set) var snapshot = RadioFourierSnapshot()
  /// Waterfall pixels (RGBA, newest row on top): each new spectrum scrolls the rows down by one
  /// and colours only the new row (dB relative to the averaged peak over −60…0 dB, squared,
  /// through the sequential map), so a frame costs one row, not the whole image.
  @ObservationIgnored private var waterfallPixels = [UInt8](
    repeating: 0, count: RadioFourierEngine.waterfallRows * RadioFourierEngine.waterfallWidth * 4)
  @ObservationIgnored private var waterfallCache: (serial: Int, image: CGImage?) = (-1, nil)
  static let waterfallRows = 90
  static let waterfallWidth = 256

  @ObservationIgnored private weak var model: RadioModel?
  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private var link: RF.BasebandLink?
  @ObservationIgnored private var voiceLink: RadioVoiceLink?
  @ObservationIgnored private var linkKey: Int?
  @ObservationIgnored private var analyzer = RF.SpectrumAnalyzer(count: 1024)
  @ObservationIgnored private var row: [Float] = []
  @ObservationIgnored private var average: [Double] = []
  @ObservationIgnored private var lastClockTime = -Double.infinity
  @ObservationIgnored private var errorCount = 0
  @ObservationIgnored private var bitCount = 0
  @ObservationIgnored private var textBits: [UInt8] = []
  @ObservationIgnored private var decoded = ""
  @ObservationIgnored private var tfTask: Task<Void, Never>?
  @ObservationIgnored private var lastTF = -Double.infinity
  @ObservationIgnored private var tfSerial = -1
  @ObservationIgnored private var micSince = 0.0
  @ObservationIgnored private var micHeld = false
  /// Microphone samples received but not yet sent (see `micBlock`).
  @ObservationIgnored private var micBuffer = RadioMicBuffer()
  @ObservationIgnored private var playback: [Float] = []
  @ObservationIgnored private var playbackRate = 48_000.0
  @ObservationIgnored private var releaseAt: Double?
  @ObservationIgnored private var idealCache: (modulation: RF.DigitalModulation, points: [SIMD2<Float>], range: Float)?

  static let micOwner = "radio.voice"
  /// Least clock time between two simulated frames (s): 60 Hz frames (and a 1/60 s Step) pass.
  static let minimumStep = 1.0 / 80

  init() { clearWaterfall() }

  func attach(model: RadioModel, app: AppModel) {
    self.model = model
    self.app = app
  }

  // MARK: Lifecycle

  func setRunning(_ on: Bool) {
    guard on != running else { return }
    running = on
    updateMic()
    if !on {
      if talking { setTalking(false) }
      flushPlayback()
      voiceOwnsAudio = false
    }
  }

  /// Message source changed (Random / Text / Voice).
  func messageChanged() {
    decoded = ""
    textBits = []
    errorCount = 0
    bitCount = 0
    linkKey = nil
    if talking { setTalking(false) }
    flushPlayback()
    updateMic()
  }

  private var voiceMode: Bool {
    guard let model else { return false }
    return model.fourier.message == .voice && RadioModel.supportsVoice(model.system.waveform)
  }

  private func updateMic() {
    guard let app else { return }
    let want = running && voiceMode
    voiceOwnsAudio = want
    guard want != micHeld else { return }
    micHeld = want
    resetMicQueue()
    if want {
      app.live.acquire(.microphone, by: Self.micOwner)
    } else {
      app.live.release(.microphone, by: Self.micOwner)
    }
  }

  private func resetMicQueue() {
    micSince = SignalClock.now()
    micBuffer = RadioMicBuffer()
  }

  // MARK: Push-to-talk

  func setTalking(_ on: Bool) {
    guard on != talking else { return }
    talking = on
    if on {
      playback = []
      bufferedSeconds = 0
      releaseAt = nil
      app?.haptics.grab()
    } else {
      releaseAt = SignalClock.now()
      app?.haptics.success()
    }
  }

  private func flushPlayback() {
    guard let app, !playback.isEmpty else {
      playback = []
      bufferedSeconds = 0
      return
    }
    app.synth.playPCM(playback, sampleRate: playbackRate)
    playback = []
    bufferedSeconds = 0
  }

  // MARK: Frames

  /// Advances the simulation by one frame when the app clock has moved since the last call
  /// (so Pause freezes it and Step advances exactly one frame), and returns the snapshot.
  /// Several panels call this per display frame; only the first advances, and at most one frame
  /// per 1/80 s of clock time: the panels' timelines are not in phase, so on a 120 Hz display
  /// they would otherwise step the simulation on every display frame between them.
  @discardableResult
  func advance() -> RadioFourierSnapshot {
    guard let app, let model else { return snapshot }
    let t = app.clock.time
    if snapshot.serial > 0, t >= lastClockTime, t - lastClockTime < Self.minimumStep { return snapshot }
    lastClockTime = t
    step(model, app)
    return snapshot
  }

  private func step(_ model: RadioModel, _ app: AppModel) {
    let config = model.basebandConfig
    let voice = voiceMode
    let analog = RadioModel.isAnalog(config.waveform)
    var h = Hasher()
    h.combine(config)
    h.combine(voice)
    let key = h.finalize()
    if key != linkKey {
      linkKey = key
      link = RF.BasebandLink(config)
      voiceLink = voice && !analog ? RadioVoiceLink(config: config) : nil
      errorCount = 0
      bitCount = 0
      textBits = []
      decoded = ""
      average = []
      tfSerial = -1
      clearWaterfall()
      Task { @MainActor [weak self] in self?.tf = nil }
    }
    var frame: RF.BasebandFrame
    var occupied = link?.occupiedBandwidth ?? 0
    var name = config.waveform.displayName
    var modulation = link?.modulation
    if voice {
      // Nothing to send yet (the microphone's jitter buffer is filling): keep the last frame.
      guard let block = micBlock(app) else { return }
      if analog, var l = link {
        frame = l.next(audio: block)
        link = l
        handleVoiceAudio(frame.audio ?? [], rate: RF.BasebandLink.audioRate, app: app, model: model)
      } else if var v = voiceLink {
        let out = v.process(block)
        voiceLink = v
        frame = out.frame
        occupied = v.settings.occupiedBandwidth
        name = "QPSK voice"
        modulation = RadioVoiceLink.modulation
        handleVoiceAudio(out.audio, rate: RadioVoiceLink.audioRate, app: app, model: model)
      } else {
        return
      }
    } else if var l = link {
      frame = l.next()
      link = l
      if let m = l.modulation, config.modulation != nil { name = "\(config.waveform.displayName) → \(m.displayName)" }
    } else {
      return
    }
    consume(frame, model: model, config: config, occupied: occupied, name: name, modulation: modulation, voice: voice)
  }

  /// The microphone samples (48 kHz) this frame sends: the voice while talking, silence of the
  /// same length otherwise, through `RadioMicBuffer` (nil while it fills).
  private func micBlock(_ app: AppModel) -> [Float]? {
    var arrived: [Float] = []
    let stream = app.streams.stream("mic.left")
    if let stream {
      let snap = stream.ring.snapshot(since: micSince)
      if let last = snap.times.last {
        micSince = last
        arrived = talking ? snap.values : [Float](repeating: 0, count: snap.values.count)
      }
    }
    return micBuffer.take(now: SignalClock.now(), arrived: arrived, microphone: stream != nil)
  }

  private func handleVoiceAudio(_ audio: [Float], rate: Double, app: AppModel, model: RadioModel) {
    guard !audio.isEmpty else { return }
    // radio.audio carries the demodulated voice at 48 kHz.
    let out48 = rate == RF.BasebandLink.audioRate ? audio : HumSynth.resample(audio, from: rate, to: RF.BasebandLink.audioRate)
    let dt = 1 / RF.BasebandLink.audioRate
    var start = SignalClock.now() - Double(out48.count) * dt
    if let last = model.streamAudio.ring.latest?.time, start <= last { start = last + dt }
    model.streamAudio.ring.append(contentsOf: out48, start: start, interval: dt)
    // Keep collecting briefly after release: the jitter buffer still holds the last words.
    let collecting = talking || (releaseAt.map { SignalClock.now() - $0 < RadioMicBuffer.latency + 0.3 } ?? false)
    if collecting {
      if AudioRoute.isPrivateOutput {
        // Headphones: no acoustic path back to the microphone, so play it live.
        app.synth.playPCM(audio, sampleRate: rate)
      } else {
        playbackRate = rate
        playback.append(contentsOf: audio)
        let cap = Int(15 * rate)
        if playback.count > cap { playback.removeFirst(playback.count - cap) }
        let seconds = (Double(playback.count) / rate * 10).rounded() / 10
        if seconds != bufferedSeconds { bufferedSeconds = seconds }
      }
    } else if releaseAt != nil {
      releaseAt = nil
      flushPlayback()
    }
  }

  private func consume(
    _ frame: RF.BasebandFrame, model: RadioModel, config: RF.BasebandLinkConfig, occupied: Double, name: String,
    modulation: RF.DigitalModulation?, voice: Bool
  ) {
    var s = RadioFourierSnapshot()
    s.serial = snapshot.serial + 1
    s.waveformName = name
    s.modulationName = modulation?.displayName
    s.sampleRate = frame.sampleRate
    s.symbolRate = frame.symbolRate
    s.occupiedBandwidth = occupied
    s.frameSamples = frame.rx.count
    s.voice = voice

    // I/Q trace.
    let source = model.traceSource == .sent ? frame.tx : frame.rx
    var isChirp = false
    if case .chirp = config.waveform { isChirp = true }
    let traceLength: Int
    switch config.waveform {
    case .linear, .fsk: traceLength = 24 * config.settings.sps
    case .chirp: traceLength = 480
    default: traceLength = 400
    }
    let m = min(source.count, max(16, traceLength))
    // A chirp is shown around the middle of its sweep, where the instantaneous frequency
    // passes through the carrier: slow at the centre, faster toward both edges.
    let start = isChirp ? max(0, (source.count - m) / 2) : 0
    s.traceI = (start..<(start + m)).map { Double(source.i[$0]) }
    s.traceQ = (start..<(start + m)).map { Double(source.q[$0]) }
    s.traceDuration = Double(m) / max(frame.sampleRate, 1)

    // Constellation (digital) or trajectory.
    if let modulation, !frame.received.isEmpty, !frame.ideal.isEmpty {
      s.received = frame.received.points(stride: max(1, frame.received.count / 1500))
      let ideal = idealPoints(modulation)
      s.ideal = ideal.points
      s.constellationRange = ideal.range
    } else {
      let pts = frame.received.isEmpty ? frame.rx.points(stride: max(1, frame.rx.count / 1500)) : frame.received.points
      s.received = pts
      s.isTrajectory = true
      var mags = pts.map { Double(simd_length($0)) }.filter(\.isFinite)
      mags.sort()
      let robust = mags.isEmpty ? 1 : mags[min(mags.count - 1, Int(Double(mags.count) * 0.98))]
      s.constellationRange = Float(max(0.5, robust * 1.2))
    }

    // Spectrum: Welch average of the received frame, smoothed across frames.
    if var a = analyzer {
      a.averagedPowerDB(frame.rx, scaling: .tone, floorDB: -160, into: &row)
      analyzer = a
      // Exponential average in linear power, in place (no per-frame array).
      if average.count != row.count {
        average = row.map { pow(10, Double($0) / 10) }
      } else {
        for k in average.indices { average[k] = 0.65 * average[k] + 0.35 * pow(10, Double(row[k]) / 10) }
      }
      let peak = average.max() ?? 1
      s.spectrum = average.map { Float(10 * log10(max($0 / max(peak, 1e-300), 1e-12))) }
      pushWaterfall(row, peakDB: Float(10 * log10(max(peak, 1e-300))))
    }

    // Errors, EVM, text.
    s.evm = frame.evm
    s.berTheory = frame.berTheory
    if !frame.sentBits.isEmpty {
      let n = min(frame.sentBits.count, frame.receivedBits.count)
      errorCount += RF.Bits.errors(frame.sentBits, frame.receivedBits)
      bitCount += n
    }
    if bitCount > 0 {
      s.measuredBER = Double(errorCount) / Double(bitCount)
      s.bitsCounted = bitCount
    }
    // An empty message sends random bits (`basebandConfig`), which would decode as noise.
    if model.fourier.message == .text, !voice, !model.fourier.text.isEmpty {
      textBits.append(contentsOf: frame.receivedBits)
      let whole = textBits.count / 8 * 8
      if whole > 0 {
        decoded += RF.Bits.toText(Array(textBits.prefix(whole)))
        textBits.removeFirst(whole)
        if decoded.count > 160 { decoded = String(decoded.suffix(160)) }
      }
      s.decodedText = decoded
    }
    snapshot = s
    scheduleTF(frame, isChirp: isChirp)
  }

  /// The ideal points to ring (none above 256: they would cover the plot) and the plot range of
  /// a modulation, built once per modulation instead of twice per frame (4096-QAM is 4096
  /// points).
  private func idealPoints(_ m: RF.DigitalModulation) -> (points: [SIMD2<Float>], range: Float) {
    if let c = idealCache, c.modulation == m { return (c.points, c.range) }
    let points = RF.Constellation(m).points
    let peak = points.reduce(0.0) { max($0, $1.magnitude) }
    let ideal = m.order <= 256 ? points.map { SIMD2(Float($0.re), Float($0.im)) } : []
    let range = Float(max(1.1, peak * 1.3))
    idealCache = (m, ideal, range)
    return (ideal, range)
  }

  /// Scrolls the waterfall down one row and writes the newest spectrum (max-hold into the
  /// display columns) at the top.
  private func pushWaterfall(_ db: [Float], peakDB: Float) {
    let w = Self.waterfallWidth
    let h = Self.waterfallRows
    guard !db.isEmpty else { return }
    let lut = Self.waterfallLUT
    let n = db.count
    waterfallPixels.withUnsafeMutableBufferPointer { buf in
      guard let base = buf.baseAddress else { return }
      memmove(base + w * 4, base, (h - 1) * w * 4)
      for x in 0..<w {
        let a = x * n / w
        let b = max(a + 1, (x + 1) * n / w)
        var v = -Float.infinity
        for i in a..<min(b, n) where db[i] > v { v = db[i] }
        let rel = v - peakDB
        // 60 dB of range, squared so the noise floor stays dark and the signal stands out.
        let t = rel.isFinite ? min(1, max(0, (rel + 60) / 60)) : 0
        let c = lut[Int((t * t * 255).rounded())]
        base[x * 4] = UInt8(c >> 24)
        base[x * 4 + 1] = UInt8((c >> 16) & 0xFF)
        base[x * 4 + 2] = UInt8((c >> 8) & 0xFF)
        base[x * 4 + 3] = 255
      }
    }
  }

  private static let waterfallLUT = RadioColorMap.sequential.lut

  private func clearWaterfall() {
    let c = Self.waterfallLUT[0]
    for k in stride(from: 0, to: waterfallPixels.count, by: 4) {
      waterfallPixels[k] = UInt8(c >> 24)
      waterfallPixels[k + 1] = UInt8((c >> 16) & 0xFF)
      waterfallPixels[k + 2] = UInt8((c >> 8) & 0xFF)
      waterfallPixels[k + 3] = 255
    }
  }

  /// The waterfall as an image, rebuilt at most once per simulated frame (newest row on top).
  func waterfallImage() -> CGImage? {
    if waterfallCache.serial == snapshot.serial { return waterfallCache.image }
    let w = Self.waterfallWidth
    let h = Self.waterfallRows
    let image = Self.image(waterfallPixels, width: w, height: h)
    waterfallCache = (snapshot.serial, image)
    return image
  }

  private static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }

  // MARK: Time–frequency

  private func scheduleTF(_ frame: RF.BasebandFrame, isChirp: Bool) {
    let now = CACurrentMediaTime()
    guard tfTask == nil, now - lastTF > 0.25 || tf == nil, snapshot.serial != tfSerial else { return }
    lastTF = now
    tfSerial = snapshot.serial
    let n = min(frame.tx.count, isChirp ? 4096 : 1024)
    guard n >= 16 else { return }
    let i = Array(frame.tx.i.prefix(n))
    let q = Array(frame.tx.q.prefix(n))
    let fs = frame.sampleRate
    let key = linkKey
    tfTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) { RadioTFResult.compute(i: i, q: q, sampleRate: fs) }.value
      guard let self else { return }
      self.tfTask = nil
      if key == self.linkKey { self.tf = result }
    }
  }
}

/// The microphone's jitter buffer for the Fourier page's voice. The microphone delivers blocks
/// every ~20–100 ms (an input-tap buffer; the SIM microphone writes every 20 ms), slower and
/// less regular than the display. Each frame used to send whatever had arrived since the last
/// one, 800 samples of silence when nothing had, and only the last 4800 when more had: silence
/// inside the held voice (and `radio.audio` running ahead of real time) at 60 frames a second,
/// lost audio at slow ones. Now arrivals queue up, frames start once `latency` is queued, and
/// each frame takes the real time since the previous one (plus a quarter of any backlog past
/// twice the latency), so the voice keeps its length and nothing is padded while the
/// microphone runs. Without a microphone (still asking, denied, or silent for `stall`) the
/// carrier runs on silence as long as the elapsed time. Pure value type (unit-testable with
/// synthetic times).
nonisolated struct RadioMicBuffer: Sendable {
  /// Depth before frames start taking (s): about one input-tap buffer, so a frame finds samples.
  static let latency = 0.12
  /// Longest backlog kept (s); older samples are dropped.
  static let backlog = 0.5
  /// Silence from the microphone for this long (s) counts as no microphone.
  static let stall = 0.25
  /// Most real time one frame takes (s): after a long gap a frame sends at most this much.
  static let maxStep = 0.25
  static let rate = RF.BasebandLink.audioRate

  /// Samples waiting, oldest first.
  private(set) var queue: [Float] = []
  private var heard = -Double.infinity
  private var primed = false
  private var lastTake: Double?

  /// One frame at `now` (s): `arrived` is what the microphone delivered since the last call
  /// (`microphone` false when it is not running). Returns the samples to send, or nil when
  /// there is nothing to send yet.
  mutating func take(now: Double, arrived: [Float], microphone: Bool) -> [Float]? {
    if microphone {
      if !arrived.isEmpty {
        heard = now
        queue.append(contentsOf: arrived)
        let cap = Int(Self.backlog * Self.rate)
        if queue.count > cap { queue.removeFirst(queue.count - cap) }
      }
      if now - heard < Self.stall {
        let target = Int(Self.latency * Self.rate)
        if !primed {
          guard queue.count >= target else { return nil }
          // Start one frame's worth from here, so `latency` stays queued (waiting to fill is
          // not time to catch up; a later wait for a late block is).
          primed = true
          lastTake = now - 1.0 / 60
        }
        var n = Int((elapsed(now) * Self.rate).rounded())
        if queue.count > 2 * target { n += (queue.count - 2 * target) / 4 }
        n = min(n, queue.count)
        guard n > 0 else { return nil }
        lastTake = now
        let block = Array(queue[0..<n])
        queue.removeFirst(n)
        return block
      }
    }
    queue.removeAll(keepingCapacity: true)
    primed = false
    let n = Int((elapsed(now) * Self.rate).rounded())
    lastTake = now
    return n > 0 ? [Float](repeating: 0, count: n) : nil
  }

  /// Real time since the last take (one frame at the first call), at most `maxStep`.
  private func elapsed(_ now: Double) -> Double {
    min(Self.maxStep, max(0, now - (lastTake ?? now - 1.0 / 60)))
  }
}
