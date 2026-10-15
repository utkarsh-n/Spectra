import AVFoundation
import Synchronization

/// Lock-free controls for one synth voice: written on the main actor, read on the audio
/// thread with relaxed atomics (Swift 6 replacement for Gyre's plain doubles). Every change
/// is smoothed per sample (τ 30 ms) on the audio side, so stale reads are inaudible.
nonisolated final class SynthVoice: Sendable {
  enum Kind: Int, Sendable {
    case off = 0
    /// A sine at `frequency` (mapped pitch for an EM frequency, a tuned tone).
    case sine
    /// White noise low-passed by `color` (0 white … 1 dark rumble).
    case noise
    /// A free-induction decay: a sine at `frequency` whose envelope restarts at 1 on each
    /// `trigger` and decays with time constant `decay` (T₂*). True-pitch NMR.
    case fid
  }

  let index: Int
  let kindRaw = Atomic<Int>(0)
  /// Hz.
  let frequency = Atomic<Double>(440)
  /// Linear 0…1.
  let level = Atomic<Double>(0)
  /// −1 (left) … 1 (right), equal-power.
  let pan = Atomic<Double>(0)
  /// FID envelope time constant in seconds.
  let decay = Atomic<Double>(1)
  /// Bumped to restart the FID envelope.
  let trigger = Atomic<Int>(0)
  /// Noise colour 0…1.
  let color = Atomic<Double>(0)

  init(index: Int) { self.index = index }

  var kind: Kind { Kind(rawValue: kindRaw.load(ordering: .relaxed)) ?? .off }

  /// A steady tone.
  func tone(_ hertz: Double, level: Double, pan: Double = 0) {
    frequency.store(hertz.isFinite ? max(0, hertz) : 0, ordering: .relaxed)
    self.level.store(Self.unit(level), ordering: .relaxed)
    self.pan.store(max(-1, min(1, pan)), ordering: .relaxed)
    kindRaw.store(Kind.sine.rawValue, ordering: .relaxed)
  }

  /// Coloured noise.
  func noise(level: Double, color: Double = 0, pan: Double = 0) {
    self.color.store(Self.unit(color), ordering: .relaxed)
    self.level.store(Self.unit(level), ordering: .relaxed)
    self.pan.store(max(-1, min(1, pan)), ordering: .relaxed)
    kindRaw.store(Kind.noise.rawValue, ordering: .relaxed)
  }

  /// Starts a ring-down at `hertz` with time constant `t2` seconds.
  func fid(_ hertz: Double, t2: Double, level: Double, pan: Double = 0) {
    frequency.store(hertz.isFinite ? max(0, hertz) : 0, ordering: .relaxed)
    decay.store(t2.isFinite ? max(0.001, t2) : 1, ordering: .relaxed)
    self.level.store(Self.unit(level), ordering: .relaxed)
    self.pan.store(max(-1, min(1, pan)), ordering: .relaxed)
    kindRaw.store(Kind.fid.rawValue, ordering: .relaxed)
    trigger.add(1, ordering: .relaxed)
  }

  /// Fades out (30 ms).
  func silence() {
    level.store(0, ordering: .relaxed)
    kindRaw.store(Kind.off.rawValue, ordering: .relaxed)
  }

  private static func unit(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
}

/// Mix-wide controls: the UI click (knob ticks and detents when sound is on) and the PCM
/// ring's gain.
nonisolated final class SynthMixControls: Sendable {
  let clickTrigger = Atomic<Int>(0)
  let clickPitch = Atomic<Double>(2400)
  let clickLevel = Atomic<Double>(0.25)
  let pcmGain = Atomic<Double>(0.8)
}

/// A mono PCM ring at the engine's output rate for demodulated audio (AM/FM voice, Patch
/// speaker sink). The audio thread reads with `withLockIfAvailable`, so it never blocks:
/// if a writer holds the lock it plays silence for that buffer.
nonisolated final class PCMRing: Sendable {
  private struct State {
    var buffer: [Float]
    var read = 0
    var count = 0
  }

  let capacity: Int
  private let state: Mutex<State>

  init(capacity: Int) {
    self.capacity = max(1, capacity)
    state = Mutex(State(buffer: [Float](repeating: 0, count: max(1, capacity))))
  }

  /// Appends samples; on overflow the oldest are dropped.
  func write(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    let cap = capacity
    state.withLock { s in
      for x in samples {
        let w = (s.read + s.count) % cap
        s.buffer[w] = x
        if s.count < cap {
          s.count += 1
        } else {
          s.read = (s.read + 1) % cap
        }
      }
    }
  }

  /// Reads up to `count` samples into `out`; returns how many were read.
  func read(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
    let cap = capacity
    return state.withLockIfAvailable { s -> Int in
      let n = min(count, s.count)
      for i in 0..<n { out[i] = s.buffer[(s.read + i) % cap] }
      s.read = (s.read + n) % cap
      s.count -= n
      return n
    } ?? 0
  }

  /// Samples waiting to play.
  var available: Int { state.withLock { $0.count } }

  func clear() {
    state.withLock { s in
      s.read = 0
      s.count = 0
    }
  }
}

/// The one synth (coherence rule R5): an `AVAudioEngine` with one `AVAudioSourceNode` that
/// mixes up to 8 voices (sine, noise, FID ring-down), a UI click and a PCM ring for
/// demodulated audio. Sound is a user option (Settings → Feedback → Sound, default off):
/// the engine starts lazily, only when `enabled` and something asks to make a sound, and
/// pauses when the app leaves the foreground.
///
/// Gyre's DSP shape: per-sample one-pole smoothing (τ 30 ms), xorshift noise, equal-power
/// pan. Handles engine configuration changes and the iOS 27 session notifications
/// (`didBecomeInactive`, `resumptionRecommendation`), route changes and media-services
/// resets.
@MainActor
final class HumSynth {
  static let shared = HumSynth()

  /// The engine, for nodes that must share it (`connect(_:format:)`); the microphone
  /// source may use its `inputNode`.
  let engine = AVAudioEngine()
  /// Claimable voices.
  let voices: [SynthVoice] = (0..<8).map(SynthVoice.init(index:))
  /// Demodulated audio waiting to play, at `outputSampleRate`.
  let pcm: PCMRing
  /// Click and PCM gain controls read by the render thread.
  let mixControls = SynthMixControls()

  /// Linear gain for demodulated audio, 0…1.
  var pcmGain: Double {
    get { mixControls.pcmGain.load(ordering: .relaxed) }
    set { mixControls.pcmGain.store(newValue.isFinite ? min(1, max(0, newValue)) : 0, ordering: .relaxed) }
  }

  /// Settings → Feedback → Sound. Turning it off pauses the engine.
  var enabled = false {
    didSet {
      guard enabled != oldValue else { return }
      if enabled {
        if !owners.isEmpty { ensureRunning() }
      } else {
        stop()
      }
    }
  }
  private(set) var running = false
  private(set) var outputSampleRate: Double = 48_000

  private var source: AVAudioSourceNode?
  private var owners: [String: Int] = [:]
  private var active = true
  private var observers: [NSObjectProtocol] = []

  private init() {
    pcm = PCMRing(capacity: 48_000 * 4)
    installObservers()
  }

  // MARK: Voices

  /// The voice reserved for `owner` (e.g. `"spin.fid"`), claiming a free one if needed.
  /// Returns nil when all 8 are taken. Starts the engine if sound is on.
  func voice(for owner: String) -> SynthVoice? {
    if let index = owners[owner] {
      ensureRunning()
      return voices[index]
    }
    let taken = Set(owners.values)
    guard let free = voices.first(where: { !taken.contains($0.index) }) else { return nil }
    owners[owner] = free.index
    ensureRunning()
    return free
  }

  /// Silences and frees `owner`'s voice.
  func releaseVoice(for owner: String) {
    guard let index = owners.removeValue(forKey: owner) else { return }
    voices[index].silence()
  }

  /// Owners holding voices.
  var claimedOwners: [String] { owners.keys.sorted() }

  /// A short click for a knob tick, detent or end stop.
  func tick(_ kind: Haptics.TickSound) {
    guard enabled else { return }
    ensureRunning()
    let (pitch, level): (Double, Double) =
      switch kind {
      case .tick: (2600, 0.12)
      case .detent: (1400, 0.22)
      case .boundary: (700, 0.28)
      }
    mixControls.clickPitch.store(pitch, ordering: .relaxed)
    mixControls.clickLevel.store(level, ordering: .relaxed)
    mixControls.clickTrigger.add(1, ordering: .relaxed)
  }

  /// Queues demodulated audio (mono) recorded at `sampleRate`; it is resampled to the
  /// engine's rate.
  func playPCM(_ samples: [Float], sampleRate: Double) {
    guard enabled, !samples.isEmpty, sampleRate > 0 else { return }
    ensureRunning()
    pcm.write(Self.resample(samples, from: sampleRate, to: outputSampleRate))
  }

  /// Attaches a node and connects it to the main mixer (iOS 27 `connectNode`).
  func connect(_ node: AVAudioNode, format: AVAudioFormat?) throws {
    if node.engine == nil { engine.attach(node) }
    try engine.connectNode(node, to: engine.mainMixerNode, format: format)
    ensureRunning()
  }

  // MARK: Lifecycle

  /// Scene phase: inactive pauses the engine; active resumes it if sound is on and voices
  /// are claimed.
  func setActive(_ isActive: Bool) {
    active = isActive
    if isActive {
      if !owners.isEmpty { ensureRunning() }
    } else {
      stop()
    }
  }

  private func ensureRunning() {
    guard enabled, active, !running else { return }
    start()
  }

  private func start() {
    if source == nil { build() }
    guard source != nil else { return }
    AudioRoute.playing = true
    AudioRoute.apply()
    do {
      try engine.start()
      running = true
    } catch {
      running = false
    }
  }

  /// Pauses the engine (keeps the graph and claimed voices).
  func stop() {
    if running { engine.pause() }
    running = false
    AudioRoute.playing = false
    pcm.clear()
  }

  private func build() {
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    outputSampleRate = rate > 0 ? rate : 48_000
    guard let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 2) else { return }
    let node = AVAudioSourceNode(
      format: format,
      renderBlock: Self.makeRenderBlock(
        voices: voices, controls: mixControls, pcm: pcm, sampleRate: outputSampleRate))
    engine.attach(node)
    do {
      try engine.connectNode(node, to: engine.mainMixerNode, format: format)
    } catch {
      engine.detach(node)
      return
    }
    engine.mainMixerNode.outputVolume = 0.9
    source = node
  }

  private func rebuild() {
    let wasRunning = running
    stop()
    if let source {
      engine.detach(source)
      self.source = nil
    }
    if wasRunning || !owners.isEmpty { ensureRunning() }
  }

  private func installObservers() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
        Task { @MainActor in
          let synth = HumSynth.shared
          guard synth.running else { return }
          synth.running = false
          synth.ensureRunning()
        }
      })
    // iOS 27 replacements for the interruption notification.
    observers.append(
      center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { _ in
        Task { @MainActor in HumSynth.shared.running = false }
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) {
        note in
        let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
        let shouldResume = context?.recommendation == .shouldResume
        Task { @MainActor in
          let synth = HumSynth.shared
          if shouldResume, !synth.owners.isEmpty { synth.ensureRunning() }
        }
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
        Task { @MainActor in
          let synth = HumSynth.shared
          if synth.running, !synth.engine.isRunning {
            synth.running = false
            synth.ensureRunning()
          }
        }
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
        Task { @MainActor in HumSynth.shared.rebuild() }
      })
  }

  /// Linear-interpolation resampler for short PCM blocks.
  nonisolated static func resample(_ input: [Float], from source: Double, to target: Double) -> [Float] {
    guard source > 0, target > 0, !input.isEmpty else { return input }
    if abs(source - target) < 0.5 { return input }
    let ratio = source / target
    let count = max(1, Int((Double(input.count) / ratio).rounded()))
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
      let x = Double(i) * ratio
      let j = Int(x)
      let f = Float(x - Double(j))
      let a = input[min(j, input.count - 1)]
      let b = input[min(j + 1, input.count - 1)]
      out[i] = a + (b - a) * f
    }
    return out
  }

  // MARK: Render (audio thread)

  /// Per-voice DSP state, touched only on the render thread.
  nonisolated private final class VoiceDSP {
    var phase = 0.0
    var frequency = 0.0
    var level = 0.0
    var pan = 0.0
    var envelope = 0.0
    var lastTrigger = 0
    var lastKind = SynthVoice.Kind.off
    var low = 0.0
  }

  /// Render-thread state shared by all voices.
  nonisolated private final class MixDSP {
    var noise: UInt32 = 22_222
    var clickEnvelope = 0.0
    var clickPhase = 0.0
    var lastClick = 0
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    deinit { scratch.deallocate() }

    func white() -> Double {
      noise ^= noise << 13
      noise ^= noise >> 17
      noise ^= noise << 5
      return Double(noise) / Double(UInt32.max) * 2 - 1
    }
  }

  /// Built in a nonisolated context so the block is not main-actor isolated: it runs on
  /// the real-time audio thread and only reads atomics and the PCM ring.
  nonisolated private static func makeRenderBlock(
    voices: [SynthVoice], controls: SynthMixControls, pcm: PCMRing, sampleRate: Double
  ) -> AVAudioSourceNodeRenderBlock {
    let dsp = voices.map { _ in VoiceDSP() }
    let mix = MixDSP()
    let smooth = 1 - exp(-1 / (0.03 * sampleRate))
    let twoPi = 2 * Double.pi
    let clickDecay = exp(-1 / (0.004 * sampleRate))
    return { _, _, frameCount, bufferList in
      let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
      guard buffers.count >= 2,
        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
        let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
      else { return noErr }
      let n = Int(frameCount)
      for i in 0..<n {
        left[i] = 0
        right[i] = 0
      }

      for (voice, d) in zip(voices, dsp) {
        let kind = voice.kind
        if kind != .off { d.lastKind = kind }
        let target = kind == .off ? 0 : voice.level.load(ordering: .relaxed)
        if target == 0, d.level < 1e-5 {
          d.level = 0
          continue
        }
        let f = voice.frequency.load(ordering: .relaxed)
        let p = voice.pan.load(ordering: .relaxed)
        let color = voice.color.load(ordering: .relaxed)
        let trigger = voice.trigger.load(ordering: .relaxed)
        if trigger != d.lastTrigger {
          d.lastTrigger = trigger
          d.envelope = 1
        }
        let decay = exp(-1 / (max(0.001, voice.decay.load(ordering: .relaxed)) * sampleRate))
        let lowK = 1 - 0.985 * color
        for i in 0..<n {
          d.level += (target - d.level) * smooth
          d.frequency += (f - d.frequency) * smooth
          d.pan += (p - d.pan) * smooth
          var s = 0.0
          switch d.lastKind {
          case .sine:
            d.phase += twoPi * d.frequency / sampleRate
            if d.phase > twoPi { d.phase -= twoPi }
            s = sin(d.phase)
          case .noise:
            d.low += (mix.white() - d.low) * lowK
            s = d.low * (1 + 2 * color)
          case .fid:
            d.phase += twoPi * d.frequency / sampleRate
            if d.phase > twoPi { d.phase -= twoPi }
            s = sin(d.phase) * d.envelope
            d.envelope *= decay
          case .off:
            s = 0
          }
          let out = s * d.level * 0.25
          let angle = (d.pan + 1) * Double.pi / 4
          left[i] += Float(out * cos(angle) * 1.414)
          right[i] += Float(out * sin(angle) * 1.414)
        }
      }

      // UI click: a 4 ms decaying sine burst.
      let clickTrigger = controls.clickTrigger.load(ordering: .relaxed)
      if clickTrigger != mix.lastClick {
        mix.lastClick = clickTrigger
        mix.clickEnvelope = controls.clickLevel.load(ordering: .relaxed)
        mix.clickPhase = 0
      }
      if mix.clickEnvelope > 1e-4 {
        let pitch = controls.clickPitch.load(ordering: .relaxed)
        for i in 0..<n {
          mix.clickPhase += twoPi * pitch / sampleRate
          let s = Float(sin(mix.clickPhase) * mix.clickEnvelope)
          left[i] += s
          right[i] += s
          mix.clickEnvelope *= clickDecay
        }
      }

      // Demodulated audio.
      var offset = 0
      let gain = Float(controls.pcmGain.load(ordering: .relaxed))
      while offset < n {
        let chunk = min(8192, n - offset)
        let got = pcm.read(into: mix.scratch, count: chunk)
        if got == 0 { break }
        for i in 0..<got {
          let s = mix.scratch[i] * gain
          left[offset + i] += s
          right[offset + i] += s
        }
        offset += got
        if got < chunk { break }
      }

      // Gentle limiter so stacked voices never clip harshly.
      for i in 0..<n {
        left[i] = tanhf(left[i])
        right[i] = tanhf(right[i])
      }
      return noErr
    }
  }
}
