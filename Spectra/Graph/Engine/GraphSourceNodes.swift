import Foundation
import simd

// Source node processors: Spectra source, Oscillator, Noise, Text/bits, Live stream,
// Motion, Gyroscope tip (Spin engine heavy top) and Spin FID (Spin engine). Physics comes from
// the engines; these only move samples.

/// Builds the processor for a node kind.
nonisolated enum NodeFactory {
  static func processor(for node: PatchNode) -> any NodeProcessor {
    switch node.kind {
    case .spectraSource: SpectraSourceProcessor()
    case .oscillator: OscillatorProcessor()
    case .noise: NoiseProcessor(seed: stableSeed(node.id))
    case .bits: BitsProcessor(seed: stableSeed(node.id))
    case .stream: StreamProcessor()
    case .motion: MotionProcessor()
    case .gyroscope: GyroscopeProcessor()
    case .spinFID: SpinFIDProcessor()
    case .modulator: ModulatorProcessor()
    case .demodulator: DemodulatorProcessor()
    case .mixer: MixerProcessor()
    case .filter: FilterProcessor()
    case .gain: GainProcessor()
    case .envelope: EnvelopeProcessor()
    case .antenna: AntennaProcessor()
    case .channel: ChannelProcessor(seed: stableSeed(node.id))
    case .medium: MediumProcessor()
    case .blackbody: BlackbodyProcessor()
    case .fft: FFTProcessor()
    case .wigner: WignerProcessor()
    case .marginal: MarginalProcessor()
    case .scope, .spectrum, .constellation, .speaker, .haptics, .ruler, .knob: SinkProcessor()
    }
  }

  /// FNV-1a of the node id: the same node gets the same noise after a relaunch.
  static func stableSeed(_ id: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in id.utf8 {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01B3
    }
    return h
  }
}

// MARK: - Spectra source

nonisolated struct SpectraSourceProcessor: NodeProcessor {
  mutating func process(_ ctx: inout NodeContext) {
    let follow = ctx.string("follow") == "A"
    let lambda = follow ? ctx.world.spectraLambda : ctx.number("lambda")
    let e0 = (follow ? ctx.world.spectraE0 : nil) ?? ctx.number("e0")
    let theta = (follow ? ctx.world.spectraTheta : nil) ?? ctx.number("polarization")
    if follow { ctx.extraProvenance = ctx.world.spectraProvenance }
    guard lambda.isFinite, lambda > 0 else {
      ctx.warn("No wavelength to send.")
      return
    }
    ctx.emit("wave", .em(EMWave(lambda: lambda, e0: e0, polarization: theta)))
    ctx.emit("frequency", control: SpectrumMarker.frequency(forLambda: lambda))
    if follow { ctx.note("Following Spectrum source A.") }
  }
}

// MARK: - Oscillator

nonisolated struct OscillatorProcessor: NodeProcessor {
  /// Phase in cycles, 0…1.
  var phase = 0.0

  static func wave(_ shape: String, _ p: Double) -> Double {
    switch shape {
    case "square": p < 0.5 ? 1 : -1
    case "saw": 2 * p - 1
    case "triangle": 1 - 4 * abs(p - 0.5)
    default: sin(2 * .pi * p)
    }
  }

  mutating func process(_ ctx: inout NodeContext) {
    let f = ctx.number("f")
    let amp = ctx.number("amp")
    let shape = ctx.string("wave")
    let rate = NodeCatalog.audioRate
    let n = ctx.world.audioCount
    let step = f.isFinite ? f / rate : 0
    if n > 0 {
      var out = [Float](repeating: 0, count: n)
      var p = phase
      for k in 0..<n {
        out[k] = Float(amp * Self.wave(shape, p))
        p += step
        p -= p.rounded(.down)
      }
      phase = p
      ctx.emit("out", .audio(RealBlock(samples: out, sampleRate: rate, startTime: ctx.world.time)))
    } else {
      phase += f * ctx.world.dt
      phase -= phase.rounded(.down)
    }
    ctx.emit("cv", control: amp * Self.wave(shape, phase))
    if f > rate / 2 { ctx.warn("Above 24 kHz: aliased at 48 kHz.") }
  }
}

// MARK: - Noise

nonisolated struct NoiseProcessor: NodeProcessor {
  var rng: RF.SeededRandom
  var low = 0.0

  init(seed: UInt64) { rng = RF.SeededRandom(seed: seed) }

  mutating func process(_ ctx: inout NodeContext) {
    let n = ctx.world.audioCount
    guard n > 0 else { return }
    let level = ctx.number("level")
    let color = min(max(ctx.number("color"), 0), 1)
    // One-pole low-pass y += a(x − y): Var y = a/(2 − a)·Var x, so scale by √((2 − a)/a)
    // to keep the RMS at `level` whatever the colour.
    let a = 1 - 0.98 * color
    let norm = ((2 - a) / a).squareRoot()
    var out = [Float](repeating: 0, count: n)
    for k in 0..<n {
      low += a * (rng.gaussian() - low)
      out[k] = Float(level * low * norm)
    }
    ctx.emit("out", .audio(RealBlock(samples: out, sampleRate: NodeCatalog.audioRate, startTime: ctx.world.time)))
  }
}

// MARK: - Text / bits

nonisolated struct BitsProcessor: NodeProcessor {
  var rng: RF.SeededRandom
  var cursor = 0
  var textBits: [UInt8] = []
  var text = ""

  init(seed: UInt64) { rng = RF.SeededRandom(seed: seed) }

  mutating func process(_ ctx: inout NodeContext) {
    let count = max(8, Int(ctx.string("block")) ?? 1024)
    if ctx.string("mode") == "random" {
      ctx.emit("bits", .bits(BitsBlock(bits: rng.bits(count), text: nil)))
      return
    }
    let message = ctx.string("text")
    if message != text {
      text = message
      textBits = RF.Bits.fromText(message.isEmpty ? " " : message + " · ")
      cursor = 0
    }
    var out = [UInt8]()
    out.reserveCapacity(count)
    while out.count < count {
      out.append(textBits[cursor])
      cursor = (cursor + 1) % textBits.count
    }
    ctx.emit("bits", .bits(BitsBlock(bits: out, text: text)))
  }
}

// MARK: - Live stream

nonisolated struct StreamProcessor: NodeProcessor {
  mutating func process(_ ctx: inout NodeContext) {
    guard let input = ctx.world.streams[ctx.node.id] else {
      ctx.wait(ctx.string("stream").isEmpty ? "Choose a stream in the inspector." : "Waiting for the stream to start.")
      return
    }
    ctx.extraProvenance = input.provenance
    if input.block.count > 0 {
      ctx.emit("samples", .audio(input.block))
    }
    if let v = input.latest { ctx.emit("value", control: v) }
    if let iq = input.iq, iq.count > 0 {
      ctx.emit("iq", .iq(iq))
    } else if ctx.isWired("iq"), input.status == nil {
      ctx.note("I/Q needs a stream with a quadrature partner (radio.i + radio.q, spin.fid + spin.fid.q).")
    }
    ctx.status = input.status ?? ctx.status
  }
}

// MARK: - Motion

nonisolated struct MotionProcessor: NodeProcessor {
  /// Core Motion's Euler angles (yaw, pitch, roll) in degrees of a local → world quaternion:
  /// R = Rz(yaw)·Rx(pitch)·Ry(roll), the convention of the `attitude.*` streams (and of
  /// `PatchModel.gatherWorld`, which builds the quaternion from them), so the node's angles
  /// equal the streams' own.
  static func angles(_ q: simd_quatd) -> (yaw: Double, pitch: Double, roll: Double) {
    let v = q.vector
    let (x, y, z, w) = (v.x, v.y, v.z, v.w)
    // R21 = sin(pitch); R20 = −cos(pitch)·sin(roll), R22 = cos(pitch)·cos(roll);
    // R01 = −sin(yaw)·cos(pitch), R11 = cos(yaw)·cos(pitch).
    let pitch = asin(max(-1, min(1, 2 * (y * z + w * x))))
    let roll = atan2(2 * (w * y - x * z), 1 - 2 * (x * x + y * y))
    let yaw = atan2(2 * (w * z - x * y), 1 - 2 * (x * x + z * z))
    let d = 180 / Double.pi
    return (yaw * d, pitch * d, roll * d)
  }

  mutating func process(_ ctx: inout NodeContext) {
    guard let q = ctx.world.attitude else {
      ctx.wait("Waiting for motion.")
      return
    }
    ctx.extraProvenance = ctx.world.motionProvenance
    ctx.emit("attitude", .attitude(q))
    let a = Self.angles(q)
    ctx.emit("yaw", control: a.yaw)
    ctx.emit("pitch", control: a.pitch)
    ctx.emit("roll", control: a.roll)
  }
}

// MARK: - Gyroscope tip (Spin engine)

nonisolated struct GyroscopeProcessor: NodeProcessor {
  var engine = GyroscopeEngine()
  var launched = false
  var kicks = 0

  /// Direction of Earth's field used when only |B| arrives (Gyre's (0, 22, −40) µT).
  static let fieldDirection = simd_normalize(SIMD3<Double>(0, 22, -40))

  mutating func process(_ ctx: inout NodeContext) {
    var p = engine.params
    p.motorRPM = ctx.number("rpm")
    p.timeScale = ctx.number("time")
    p.gravity = ctx.number("gravity")
    p.magnet = ctx.number("magnet")
    engine.params = p
    if !launched {
      engine.launch()
      launched = true
    }
    var env = HeavyTopEnvironment()
    let microtesla = ctx.control("field") ?? 50
    env.magneticField = Self.fieldDirection * microtesla * 1e-6
    if let q = ctx.world.attitude, let w = ctx.world.rotationRate {
      env.deviceRate = q.act(w)
      ctx.extraProvenance = ctx.world.motionProvenance
    }
    if let events = ctx.input("kick")?.payload.events, !events.isEmpty {
      for s in events.strengths {
        kicks += 1
        engine.kick(strength: min(max(s, 0), 1), angle: Double(kicks) * 2.399963)
      }
    }
    engine.advance(dtReal: ctx.world.dt, environment: env)
    let tip = engine.drainTip()
    if !tip.isEmpty {
      var iq = RF.IQBuffer(count: tip.count)
      for (k, s) in tip.enumerated() {
        iq.i[k] = Float(s.x)
        iq.q[k] = Float(s.y)
      }
      ctx.emit("tip", .iq(IQBlock(iq: iq, sampleRate: engine.wallClockTipRate, startTime: ctx.world.time)))
    }
    let t = engine.telemetry
    ctx.emit("tipX", control: engine.tip.x)
    ctx.emit("precession", control: t.precessionHz)
    ctx.emit("nod", control: t.nutationHz)
    ctx.emit("spin", control: t.rpm)
  }
}

// MARK: - Spin FID (Spin engine)

nonisolated struct SpinFIDProcessor: NodeProcessor {
  var source: SpinFIDSource?
  var knobField = Double.nan
  var reference: Double?
  /// Fractional I/Q samples carried between steps.
  var iqDebt = 0.0
  static let iqRate = 4000.0

  mutating func process(_ ctx: inout NodeContext) {
    let species = SpinSpecies(rawValue: ctx.string("species")) ?? .protonWater
    let knob = ctx.number("field") * 1e-6
    if source == nil || source?.species != species {
      source = SpinFIDSource(
        species: species, field: knob, sampleRate: NodeCatalog.audioRate, t2Star: ctx.number("t2"),
        level: ctx.number("level"), repeatInterval: ctx.number("repeat"))
      source?.pulse()
      knobField = knob
      reference = nil
    }
    guard var src = source else { return }
    src.t2Star = ctx.number("t2")
    src.level = ctx.number("level")
    src.repeatInterval = ctx.number("repeat")
    if let microtesla = ctx.control("field") {
      src.updateField(microtesla * 1e-6, dt: ctx.world.dt)
      knobField = .nan
    } else if knob != knobField {
      src.setField(knob)
      knobField = knob
    }
    if let events = ctx.input("pulse")?.payload.events, !events.isEmpty {
      src.pulse(amplitude: min(1, max(0.05, events.strengths.max() ?? 1)))
    }
    let n = ctx.world.audioCount
    if n > 0 {
      let audio = src.renderAudio(n)
      ctx.emit("audio", .audio(RealBlock(samples: audio, sampleRate: NodeCatalog.audioRate, startTime: ctx.world.time)))
    }
    // Heterodyned I/Q: a reference 250 Hz below the line keeps it visible at a 4 kHz rate.
    let larmor = src.larmorHz
    if reference == nil || abs(larmor - (reference ?? 0) - 250) > 1500 {
      reference = max(0, (larmor - 250).rounded())
    }
    iqDebt += ctx.world.dt * Self.iqRate
    let m = Int(iqDebt.rounded(.down))
    iqDebt -= Double(m)
    if m > 0, let ref = reference {
      let bb = src.renderBaseband(count: m, sampleRate: Self.iqRate, referenceHz: ref)
      var iq = RF.IQBuffer(count: bb.count)
      for (k, s) in bb.enumerated() {
        iq.i[k] = Float(s.x)
        iq.q[k] = Float(s.y)
      }
      ctx.emit(
        "iq", .iq(IQBlock(iq: iq, sampleRate: Self.iqRate, startTime: ctx.world.time, carrierHz: ref, bandwidth: 0)))
    }
    ctx.emit("larmor", control: larmor)
    switch src.voice.mode {
    case .truePitch: ctx.note("True pitch: \(Self.hz(larmor)).")
    case .mapped: ctx.note("Mapped pitch: \(Self.hz(larmor)) is beyond hearing.")
    }
    source = src
  }

  static func hz(_ f: Double) -> String {
    f >= 1e6 ? String(format: "%.3f MHz", f / 1e6) : (f >= 1e3 ? String(format: "%.2f kHz", f / 1e3) : String(format: "%.1f Hz", f))
  }
}

// MARK: - Sinks (state lives in the model; the evaluator handles Knob targets)

nonisolated struct SinkProcessor: NodeProcessor {
  var lastRulerLambda = Double.nan

  /// The declared rate of a control cable published on the scope bus: 46.875 Hz in
  /// audio-rate graphs (one value per 1024-sample block), a nominal 60 Hz frame rate otherwise.
  static func controlRate(_ world: GraphInputs) -> Double {
    let block = Double(NodeCatalog.blockSize) / NodeCatalog.audioRate
    return abs(world.dt - block) < 1e-9 ? NodeCatalog.audioRate / Double(NodeCatalog.blockSize) : 60
  }

  mutating func process(_ ctx: inout NodeContext) {
    let id = ctx.node.id
    switch ctx.node.kind {
    case .scope:
      var any = false
      for port in ["ch1", "ch2", "ch3", "ch4"] {
        guard let v = ctx.input(port) else { continue }
        any = true
        let label = "\(ctx.node.title) \(port.uppercased()) · \(ctx.sourceTitles[port] ?? "")"
        switch v.payload {
        case .audio(let b):
          ctx.effects.append(.scope(node: id, channel: port, block: b, label: label, provenance: v.provenance, lambda: nil))
        case .iq(let b):
          let lambda = b.carrierHz.map { SpectrumMarker.lambda(forFrequency: $0) }
          ctx.effects.append(
            .scope(
              node: id, channel: port, block: RealBlock(samples: b.iq.i, sampleRate: b.sampleRate, startTime: b.startTime, unit: "I"),
              label: label + " I", provenance: v.provenance, lambda: lambda))
          ctx.effects.append(
            .scope(
              node: id, channel: port + ".q",
              block: RealBlock(samples: b.iq.q, sampleRate: b.sampleRate, startTime: b.startTime, unit: "Q"),
              label: label + " Q", provenance: v.provenance, lambda: lambda))
        case .control(let x):
          // The declared step rate, not 1/dt: frame steps jitter (and a heavy step waits a
          // frame), and a stream whose declared rate moved would be re-registered, losing its
          // history. Each sample still carries its own step time.
          let rate = Self.controlRate(ctx.world)
          ctx.effects.append(
            .scope(
              node: id, channel: port, block: RealBlock(samples: [Float(x)], sampleRate: rate, startTime: ctx.world.time, unit: ""),
              label: label, provenance: v.provenance, lambda: nil))
        default: break
        }
      }
      if !any { ctx.wait("Cable up to four signals into CH1–CH4.") }
    case .speaker:
      guard let b = ctx.audio("in") else {
        ctx.wait("Cable audio into the speaker.")
        return
      }
      ctx.effects.append(.play(node: id, samples: b.samples, sampleRate: b.sampleRate, level: ctx.number("level")))
    case .haptics:
      let gain = ctx.number("gain")
      var level: Double?
      if let v = ctx.control("intensity") {
        level = v
      } else if let b = ctx.audio("intensity") {
        level = b.rms * 2.0.squareRoot()
      }
      if let level {
        ctx.effects.append(.hum(node: id, intensity: min(1, max(0, level * gain)), sharpness: ctx.number("sharpness")))
      }
      if let e = ctx.input("events")?.payload.events {
        for s in e.strengths { ctx.effects.append(.tap(node: id, strength: min(1, max(0, s * gain)))) }
      }
      if level == nil, !ctx.isConnected("events") { ctx.wait("Cable a control, audio or events in to feel it.") }
    case .ruler:
      var lambda: Double?
      if let w = ctx.input("in")?.payload.em {
        lambda = w.lambda
      } else if let f = ctx.control("in"), f > 0 {
        lambda = SpectrumMarker.lambda(forFrequency: f)
      }
      guard let lambda, lambda.isFinite, lambda > 0 else {
        ctx.wait("Cable a wave or a frequency in.")
        return
      }
      lastRulerLambda = lambda
      ctx.effects.append(
        .ruler(node: id, lambda: lambda, label: ctx.sourceTitles["in"] ?? ctx.node.title, provenance: ctx.inputProvenance))
    case .knob:
      if ctx.string("target").isEmpty {
        ctx.wait("Pick a knob to drive.")
      } else if !ctx.isConnected("cv") {
        ctx.wait("Cable a control signal into CV.")
      }
    case .spectrum, .constellation:
      if ctx.inputs.isEmpty { ctx.wait("Cable a signal in.") }
    default:
      break
    }
  }
}
