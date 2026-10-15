import Foundation
import simd

// Process node processors: Mixer, Filter, Gain, Envelope follower (Gyre's conditioner),
// Antenna and Channel (RF engine), Medium (Core Matter bench), Blackbody (Core Wien),
// FFT (RF DSP), Wigner and Marginal (Phase engine).

/// True when two sample rates differ by more than 1 % (a real change, not timing jitter).
nonisolated func rateChanged(_ a: Double, _ b: Double) -> Bool {
  abs(a - b) > 0.01 * max(abs(a), abs(b))
}

/// Linear resampling of an I/Q block (per component).
nonisolated func resampleIQ(_ x: RF.IQBuffer, from a: Double, to b: Double) -> RF.IQBuffer {
  guard a > 0, b > 0, abs(a - b) > 1e-9 * a else { return x }
  return RF.IQBuffer(i: RF.DSP.resampleLinear(x.i, from: a, to: b), q: RF.DSP.resampleLinear(x.q, from: a, to: b))
}

// MARK: - Mixer

nonisolated struct MixerProcessor: NodeProcessor {
  var nco: RF.DSP.NCO?

  mutating func process(_ ctx: inout NodeContext) {
    guard let a = ctx.input("a") else {
      ctx.wait("Cable a signal into A.")
      return
    }
    let b = ctx.input("b")
    switch (a.payload, b?.payload) {
    case (.audio(let x), nil):
      var y = x.samples
      prepare(ctx, rate: x.sampleRate)
      nco?.mixReal(&y)
      ctx.emit("out", .audio(RealBlock(samples: y, sampleRate: x.sampleRate, startTime: x.startTime, unit: x.unit)))
    case (.iq(let x), nil):
      var y = x.iq
      prepare(ctx, rate: x.sampleRate)
      nco?.mix(&y)
      var out = x
      out.iq = y
      ctx.emit("out", .iq(out))
    case (.audio(let x), .audio(let yb)?):
      let y = abs(yb.sampleRate - x.sampleRate) > 1e-9 ? RF.DSP.resampleLinear(yb.samples, from: yb.sampleRate, to: x.sampleRate) : yb.samples
      if yb.sampleRate != x.sampleRate { ctx.note("B resampled to A's rate.") }
      var out = x.samples
      for k in out.indices { out[k] *= y.isEmpty ? 0 : y[min(k, y.count - 1)] }
      ctx.emit("out", .audio(RealBlock(samples: out, sampleRate: x.sampleRate, startTime: x.startTime, unit: x.unit)))
    case (.iq(let x), .iq(let yb)?):
      let y = resampleIQ(yb.iq, from: yb.sampleRate, to: x.sampleRate)
      var out = x
      out.iq = Self.multiply(x.iq, y)
      ctx.emit("out", .iq(out))
    case (.iq(let x), .audio(let yb)?):
      let y = RF.IQBuffer(real: RF.DSP.resampleLinear(yb.samples, from: yb.sampleRate, to: x.sampleRate))
      var out = x
      out.iq = Self.multiply(x.iq, y)
      ctx.emit("out", .iq(out))
    case (.audio(let x), .iq(let yb)?):
      let y = resampleIQ(yb.iq, from: yb.sampleRate, to: x.sampleRate)
      var out = yb
      out.iq = Self.multiply(RF.IQBuffer(real: x.samples), y)
      out.sampleRate = x.sampleRate
      out.startTime = x.startTime
      ctx.emit("out", .iq(out))
    default:
      ctx.warn("The mixer takes samples or I/Q.")
    }
  }

  private mutating func prepare(_ ctx: NodeContext, rate: Double) {
    let f = ctx.number("lo")
    if nco == nil || nco?.sampleRate != rate { nco = RF.DSP.NCO(frequency: f, sampleRate: rate) }
    nco?.frequency = f
  }

  /// Complex product over A's length (B held at its last sample when shorter).
  static func multiply(_ a: RF.IQBuffer, _ b: RF.IQBuffer) -> RF.IQBuffer {
    var out = RF.IQBuffer(count: a.count)
    guard b.count > 0 else { return out }
    for k in 0..<a.count {
      let j = min(k, b.count - 1)
      out.i[k] = a.i[k] * b.i[j] - a.q[k] * b.q[j]
      out.q[k] = a.i[k] * b.q[j] + a.q[k] * b.i[j]
    }
    return out
  }
}

// MARK: - Filter

nonisolated struct FilterProcessor: NodeProcessor {
  var key = ""
  var re: RF.DSP.Biquad?
  var im: RF.DSP.Biquad?

  mutating func process(_ ctx: inout NodeContext) {
    guard let v = ctx.input("in") else {
      ctx.wait("Cable a signal in.")
      return
    }
    let rate: Double
    switch v.payload {
    case .audio(let b): rate = b.sampleRate
    case .iq(let b): rate = b.sampleRate
    default:
      ctx.warn("The filter takes samples or I/Q.")
      return
    }
    guard rate > 0 else {
      ctx.warn("This stream has no steady rate to filter.")
      return
    }
    let response = RF.DSP.FilterResponse(rawValue: ctx.string("response")) ?? .lowpass
    let asked = ctx.number("f")
    let f = min(max(asked, 1e-3), 0.45 * rate)
    if asked > 0.45 * rate { ctx.note("Corner held below this signal's Nyquist frequency.") }
    let q = ctx.number("q")
    let k = "\(response.rawValue)|\(f)|\(q)|\((rate / 10).rounded())"
    if k != key {
      key = k
      let made = RF.DSP.Biquad(response, frequency: f, sampleRate: rate, q: q)
      re = made
      im = made
    }
    switch v.payload {
    case .audio(var b):
      re?.process(&b.samples)
      ctx.emit("out", .audio(b))
    case .iq(var b):
      re?.process(&b.iq.i)
      im?.process(&b.iq.q)
      ctx.emit("out", .iq(b))
    default: break
    }
  }
}

// MARK: - Gain

nonisolated struct GainProcessor: NodeProcessor {
  mutating func process(_ ctx: inout NodeContext) {
    guard let v = ctx.input("in") else {
      ctx.wait("Cable a signal in.")
      return
    }
    let g = pow(10, ctx.number("gain") / 20)
    switch v.payload {
    case .audio(var b):
      for k in b.samples.indices { b.samples[k] *= Float(g) }
      ctx.emit("out", .audio(b))
    case .iq(var b):
      b.iq.scale(by: Float(g))
      ctx.emit("out", .iq(b))
    case .control(let x):
      ctx.emit("out", control: x * g)
    default:
      ctx.warn("Gain takes samples, I/Q or a control.")
    }
  }
}

// MARK: - Envelope follower (Gyre's conditioner, gyre-integration §7)

nonisolated struct EnvelopeProcessor: NodeProcessor {
  var floor = 0.0
  var envelope = 0.0
  var average = 0.0
  var clock = 0.0
  var lastOnset = -Double.infinity

  /// One block of Gyre's `envelope()`: dB = 20 log10(level·gain); raw = clamp((dB + 55)/45);
  /// the floor falls with τ 0.4 s and rises with τ 20 s; attack 30 ms, release 350 ms.
  mutating func condition(level: Double, dt: Double) -> Double {
    let db = 20 * log10(max(level, 1e-6))
    let raw = min(max((db + 55) / 45, 0), 1)
    floor += (raw - floor) * (1 - exp(-dt / (raw < floor ? 0.4 : 20)))
    let above = max(0, raw - floor - 0.04) / max(1 - floor, 0.25)
    let tau = above > envelope ? 0.03 : 0.35
    envelope += (min(above * 1.5, 1) - envelope) * (1 - exp(-dt / tau))
    return envelope
  }

  /// Gyre's onset rule: RMS above 1.9 × the 0.25 s average + 0.004, 0.12 s refractory.
  /// Returns the onset strength (rms / average, at most 12) or nil.
  mutating func onset(rms: Double, dt: Double) -> Double? {
    clock += dt
    var hit: Double?
    if rms > average * 1.9 + 0.004, clock - lastOnset > 0.12 {
      hit = min(rms / max(average, 0.002), 12)
      lastOnset = clock
    }
    average += (rms - average) * min(1, dt / 0.25)
    return hit
  }

  mutating func process(_ ctx: inout NodeContext) {
    guard let b = ctx.audio("in") else {
      ctx.wait("Cable samples in.")
      return
    }
    let dt = b.isIrregular ? max(ctx.world.dt, 1e-3) : max(b.duration, 1e-4)
    let gain = pow(10, ctx.number("gain") / 20)
    let rms = b.rms * gain
    ctx.emit("env", control: condition(level: rms, dt: dt))
    if let s = onset(rms: rms, dt: dt) {
      ctx.emit("onsets", .event(EventBlock(times: [b.startTime], strengths: [s / 12])))
    }
  }
}

// MARK: - Antenna (RF engine pattern model)

nonisolated struct AntennaProcessor: NodeProcessor {
  var key = ""
  var model: RF.AntennaModel?

  /// The receiver's direction in the world frame: θ from straight up toward +x.
  static func farEndDirection(degrees: Double) -> SIMD3<Double> {
    let t = degrees * .pi / 180
    return SIMD3(sin(t), 0, cos(t))
  }

  mutating func process(_ ctx: inout NodeContext) {
    let sig = ctx.iq("signal")
    let frequency = sig?.carrierHz ?? ctx.number("frequency")
    let style = RF.AntennaStyle(rawValue: ctx.string("style")) ?? .phasedArray
    var local = Self.farEndDirection(degrees: ctx.number("farEnd"))
    if ctx.flag("follow") {
      if let q = ctx.input("attitude")?.payload.attitude {
        local = RF.AntennaModel.localDirection(world: local, attitude: q)
      } else {
        ctx.note("Follow phone needs the Attitude input.")
      }
    }
    var p = RF.AntennaParameters(style: style, frequency: frequency)
    if style == .phasedArray {
      p.arrayNx = Int(ctx.number("elements").rounded())
      p.arrayNy = 1
      p.arraySpacing = 0.5
      var steer = ctx.number("steer")
      if let s = ctx.control("steer") { steer = asin(min(1, max(-1, s))) * 180 / .pi }
      p.steerTheta = steer
      p.steerPhi = 0
      if ctx.flag("beamLock") {
        let aim = RF.AntennaModel.steering(toward: local)
        p.steerTheta = aim.theta
        p.steerPhi = aim.phi
      }
      // Quantize steering so a moving input does not rebuild the pattern every frame.
      p.steerTheta = (p.steerTheta * 4).rounded() / 4
      p.steerPhi = (p.steerPhi * 4).rounded() / 4
    }
    let k = "\(style.rawValue)|\(p.frequency)|\(p.arrayNx)|\(p.steerTheta)|\(p.steerPhi)"
    if k != key || model == nil {
      key = k
      model = RF.AntennaModel(p)
    }
    guard let model else { return }
    let g = model.gainDBi(toward: local)
    let gain = g.isFinite ? g : -60
    ctx.emit("gain", control: gain)
    // A wire along +z has a null straight overhead: say so rather than leave a dead link.
    if gain < -20, ctx.status == nil { ctx.note("The far end sits in a null of this pattern (\(Int(gain.rounded())) dBi).") }
    guard var out = sig else {
      if ctx.status == nil {
        if ctx.isWired("gain") {
          ctx.note("Receive antenna: its gain feeds the cable from Gain.")
        } else {
          ctx.wait("Cable a signal in to transmit, or Gain into a Channel's Rx gain to receive.")
        }
      }
      return
    }
    out.antennaGainDBi += gain
    if out.carrierHz == nil { out.carrierHz = frequency }
    ctx.emit("signal", .iq(out))
  }
}

// MARK: - Channel (RF engine link budget + channel simulator)

nonisolated struct ChannelProcessor: NodeProcessor {
  let seed: UInt64
  var budgetKey = ""
  var budget: RF.LinkBudgetResult?
  var simKey = ""
  var simulator: RF.ChannelSimulator?

  init(seed: UInt64) { self.seed = seed }

  static func propagation(_ key: String) -> RF.PropagationModel {
    switch key {
    case "indoor": .tr38901(.indoorOfficeNLOS)
    case "urban": .tr38901(.urbanMacroNLOS)
    case "logDistance": .logDistance(exponent: 3, referenceDistance: 1)
    default: .freeSpace
    }
  }

  /// The link budget for a carrier and bandwidth with this node's knobs.
  static func linkInput(_ ctx: NodeContext, frequency: Double, bandwidth: Double, txGain: Double, polarizationDB: Double)
    -> RF.LinkBudgetInput
  {
    var x = RF.LinkBudgetInput(frequency: frequency, bandwidth: bandwidth)
    x.txPowerDBm = ctx.number("txPower")
    x.txGainDBi = txGain
    x.rxGainDBi = ctx.control("rxGain") ?? 0
    x.distance = ctx.number("distance")
    x.model = propagation(ctx.string("environment"))
    let walls = Int(ctx.number("walls").rounded())
    if walls > 0, let m = RF.Building.Material(rawValue: ctx.string("material")) {
      x.walls = [RF.WallLayer(m, count: walls)]
    }
    x.noiseFigureDB = ctx.number("noiseFigure")
    x.polarizationLossDB = max(0, -polarizationDB)
    return x
  }

  mutating func process(_ ctx: inout NodeContext) {
    guard let sig = ctx.iq("signal") else {
      ctx.wait("Cable a signal in.")
      return
    }
    let frequency = sig.carrierHz ?? 2.44e9
    if sig.carrierHz == nil { ctx.note("No carrier on the cable: assuming 2.44 GHz.") }
    let bandwidth = sig.noiseBandwidth
    let input = Self.linkInput(
      ctx, frequency: frequency, bandwidth: bandwidth, txGain: sig.antennaGainDBi, polarizationDB: sig.polarizationDB)
    let bk = "\(frequency)|\(bandwidth)|\(input.txPowerDBm)|\(input.txGainDBi)|\(input.rxGainDBi)|\(input.distance)|\(ctx.string("environment"))|\(input.walls.map { "\($0.material.rawValue)\($0.count)" })|\(input.noiseFigureDB)|\(input.polarizationLossDB)"
    if bk != budgetKey || budget == nil {
      budgetKey = bk
      budget = RF.LinkBudget.evaluate(input)
    }
    guard let r = budget else { return }
    // SNR in the signal's bandwidth → per-sample SNR against the block's own power.
    let ratio = sig.sampleRate > 0 && bandwidth > 0 ? sig.sampleRate / bandwidth : 1
    let perSample = r.snrDB.isFinite ? r.snrDB - 10 * log10(max(ratio, 1)) : Double.nan
    let fading: RF.FadingKind =
      switch ctx.string("fading") {
      case "rayleigh": .rayleigh
      case "rician": .rician(k: 5)
      default: .none
      }
    let snrKey = perSample.isFinite ? (perSample * 4).rounded() / 4 : 999
    let sk = "\(snrKey)|\(ctx.number("spread"))|\(ctx.number("doppler"))|\(ctx.string("fading"))|\(sig.sampleRate)"
    if sk != simKey || simulator == nil {
      simKey = sk
      var c = RF.ChannelConfig(
        snrDB: perSample.isFinite ? snrKey : nil, delaySpread: ctx.number("spread"), dopplerHz: ctx.number("doppler"),
        fading: fading, seed: seed)
      c.measureSignalPower = true
      simulator = RF.ChannelSimulator(config: c, sampleRate: sig.sampleRate)
    }
    guard var sim = simulator else { return }
    var out = sig
    out.iq = sim.process(sig.iq)
    simulator = sim
    ctx.emit("signal", .iq(out))
    ctx.emit("snr", control: r.snrDB)
    ctx.emit("rxPower", control: r.receivedPowerDBm)
    if let first = r.notes.first { ctx.note(first) }
  }
}

// MARK: - Medium (Core Matter bench)

nonisolated struct MediumProcessor: NodeProcessor {
  mutating func process(_ ctx: inout NodeContext) {
    guard let w = ctx.input("wave")?.payload.em else {
      ctx.wait("Cable a wave in.")
      return
    }
    guard let key = SpecimenKey(rawValue: ctx.string("specimen")) else { return }
    let r = key.evaluate(w.lambda)
    if let p = Provenance(rawValue: r.source.rawValue) { ctx.extraProvenance = [p] }
    guard let t = r.transmission, t.isFinite else {
      ctx.warn("No transmission figure for \(key.name) here.")
      return
    }
    var out = w
    out.e0 = w.e0 * max(0, t).squareRoot()
    ctx.emit("wave", .em(out))
    ctx.emit("transmission", control: t)
  }
}

// MARK: - Blackbody (Core Wien peak)

nonisolated struct BlackbodyProcessor: NodeProcessor {
  mutating func process(_ ctx: inout NodeContext) {
    let t = ctx.control("temperature") ?? ctx.number("temperature")
    guard t.isFinite, t > 0 else {
      ctx.warn("Temperature must be above 0 K.")
      return
    }
    let lambda = Wave.wienPeak(t)
    ctx.emit("wave", .em(EMWave(lambda: lambda, e0: 1, polarization: 0)))
    ctx.emit("peak", control: lambda)
    if ctx.isConnected("temperature") { ctx.note("A lamp's color temperature is a match, not a true blackbody.") }
  }
}

// MARK: - FFT (RF engine spectrum analyzer)

nonisolated struct FFTProcessor: NodeProcessor {
  var real: [Float] = []
  var complex = RF.IQBuffer()
  var rate = 0.0
  var isComplex = false
  var carrier: Double?
  var analyzerSize = 0
  var analyzer: RF.SpectrumAnalyzer?
  var averaged: [Float] = []

  mutating func process(_ ctx: inout NodeContext) {
    let size = max(64, Int(ctx.string("size")) ?? 4096)
    let alpha = Float(min(max(ctx.number("average"), 0), 0.99))
    var fresh = false
    switch ctx.input("in")?.payload {
    case .audio(let b)?:
      guard !b.isIrregular else {
        ctx.warn("Irregular stream: no steady rate to transform.")
        return
      }
      if isComplex || rateChanged(b.sampleRate, rate) { reset(rate: b.sampleRate, complex: false) }
      real.append(contentsOf: b.samples)
      if real.count > size { real.removeFirst(real.count - size) }
      fresh = b.count > 0
    case .iq(let b)?:
      if !isComplex || rateChanged(b.sampleRate, rate) { reset(rate: b.sampleRate, complex: true) }
      carrier = b.carrierHz
      complex.append(b.iq)
      if complex.count > size { complex = complex.slice((complex.count - size)..<complex.count) }
      fresh = b.count > 0
    case nil:
      ctx.wait("Cable samples or I/Q in.")
      return
    default:
      ctx.warn("The FFT takes samples or I/Q.")
      return
    }
    guard fresh else { return }
    let have = isComplex ? complex.count : real.count
    var n = size
    if have < size {
      n = 64
      while n * 2 <= have { n *= 2 }
      guard have >= 64 else {
        ctx.wait("Collecting samples: \(have) of \(size).")
        return
      }
      ctx.note("Collecting: \(have) of \(size) samples, transforming \(n).")
    }
    if n != analyzerSize {
      analyzerSize = n
      analyzer = RF.SpectrumAnalyzer(count: n)
      averaged = []
    }
    guard var a = analyzer else { return }
    var db: [Float]
    var start = 0.0
    if isComplex {
      db = a.powerDB(complex.slice((complex.count - n)..<complex.count))
      start = -rate / 2
    } else {
      db = a.realSpectrumDB(Array(real.suffix(n)))
    }
    analyzer = a
    if averaged.count == db.count, alpha > 0 {
      for k in db.indices { db[k] = alpha * averaged[k] + (1 - alpha) * db[k] }
    }
    averaged = db
    let bin = rate / Double(n)
    var peak: Double?
    if isComplex {
      if let k = db.indices.max(by: { db[$0] < db[$1] }) { peak = start + Double(k) * bin }
    } else {
      peak = RF.SpectrumAnalyzer.peak(ofOneSided: db, sampleRate: rate, count: n)?.frequency
    }
    ctx.emit(
      "spectrum",
      .spectrum(
        SpectrumFrame(
          values: db, startFrequency: start, binWidth: bin, isDB: true, sampleRate: rate, peakHz: peak,
          carrierHz: isComplex ? carrier : nil)))
    if let peak { ctx.emit("peak", control: peak) }
  }

  private mutating func reset(rate r: Double, complex c: Bool) {
    rate = r
    isComplex = c
    real = []
    complex = RF.IQBuffer()
    averaged = []
  }
}

// MARK: - Wigner (Phase engine, Utkarsh's convention (C))

nonisolated struct WignerProcessor: NodeProcessor {
  var real: [Float] = []
  var complex = RF.IQBuffer()
  var rate = 0.0
  var start = 0.0
  var isComplex = false
  var fresh = 0
  var stepsSince = 0
  var image: TFImage?
  var key = ""

  static func mode(_ key: String) -> Phase.TimeFrequencyMode {
    Phase.TimeFrequencyMode(rawValue: key) ?? .wignerVille
  }

  mutating func process(_ ctx: inout NodeContext) {
    let length = max(64, Int(ctx.string("length")) ?? 1024)
    let mode = Self.mode(ctx.string("mode"))
    switch ctx.input("in")?.payload {
    case .audio(let b)?:
      guard !b.isIrregular, b.sampleRate > 0 else {
        ctx.warn("Irregular stream: resample it before a Wigner view.")
        return
      }
      if isComplex || rateChanged(b.sampleRate, rate) { reset(b.sampleRate, complex: false) }
      real.append(contentsOf: b.samples)
      if real.count > length { real.removeFirst(real.count - length) }
      start = b.startTime + b.duration - Double(real.count) / rate
      fresh += b.count
    case .iq(let b)?:
      if !isComplex || rateChanged(b.sampleRate, rate) { reset(b.sampleRate, complex: true) }
      complex.append(b.iq)
      if complex.count > length { complex = complex.slice((complex.count - length)..<complex.count) }
      start = b.startTime + b.duration - Double(complex.count) / rate
      fresh += b.count
    case nil:
      ctx.wait("Cable samples or I/Q in.")
      return
    default:
      ctx.warn("The Wigner node takes samples or I/Q.")
      return
    }
    let have = isComplex ? complex.count : real.count
    let k = "\(mode.rawValue)|\(length)"
    stepsSince += 1
    // Recompute when a quarter of the record is new, at most every sixth step at audio rate
    // (about 8 pictures a second).
    let due = (fresh >= max(16, length / 4) && stepsSince >= (ctx.world.dt < 0.03 ? 6 : 1)) || k != key || image == nil
    if due, have >= 32 {
      key = k
      fresh = 0
      stepsSince = 0
      let request = Phase.TimeFrequencyRequest(mode: mode, rows: 128, columns: 128)
      let tf: Phase.TimeFrequencyImage
      if isComplex {
        let z = Phase.Signal.fromIQ(i: complex.i, q: complex.q, sampleRate: rate, origin: start)
        tf = Phase.timeFrequency(complex: z, request: request)
      } else {
        tf = Phase.timeFrequency(real: real, sampleRate: rate, origin: start, request: request)
      }
      image = TFImage(image: tf, mode: mode, sampleRate: rate, complex: isComplex, duration: Double(have) / rate)
    }
    if have < length { ctx.note("Record \(have) of \(length) samples.") }
    if let image { ctx.emit("image", .image(image)) }
  }

  private mutating func reset(_ r: Double, complex c: Bool) {
    rate = r
    isComplex = c
    real = []
    complex = RF.IQBuffer()
    image = nil
    fresh = 0
  }
}

// MARK: - Marginal (Phase engine)

nonisolated struct MarginalProcessor: NodeProcessor {
  /// Largest |M1 − |z|²| over the rows, relative to the largest |z|² (exact Wigner: round-off).
  static func timeMarginalError(_ tf: Phase.TimeFrequencyImage) -> Double {
    let peak = tf.intensity.map(abs).max() ?? 0
    guard peak > 0, tf.timeMarginal.count == tf.intensity.count else { return 0 }
    var worst = 0.0
    for k in tf.intensity.indices { worst = max(worst, abs(tf.timeMarginal[k] - tf.intensity[k])) }
    return worst / peak
  }

  mutating func process(_ ctx: inout NodeContext) {
    guard let img = ctx.input("image")?.payload.image else {
      ctx.wait("Cable a Wigner image in.")
      return
    }
    let plane = img.image.plane
    let rowStep = plane.rowAxis.step
    ctx.emit(
      "time",
      .audio(
        RealBlock(
          samples: img.image.timeMarginal.map(Float.init), sampleRate: rowStep > 0 ? 1 / rowStep : 0,
          startTime: plane.rowAxis.start, unit: "|x|²")))
    ctx.emit(
      "frequency",
      .spectrum(
        SpectrumFrame(
          values: img.image.frequencyMarginal.map(Float.init), startFrequency: plane.columnAxis.start,
          binWidth: plane.columnAxis.step, isDB: false, sampleRate: img.sampleRate, peakHz: nil, carrierHz: nil)))
    let error = Self.timeMarginalError(img.image)
    ctx.emit("error", control: error)
    switch img.mode {
    case .wignerVille, .pseudoWigner:
      ctx.note(
        error < 1e-6
          ? "Marginal consistent with |x(t)|²."
          : "Marginal off by \(String(format: "%.2g", error * 100)) % of the peak.")
    case .smoothedPseudoWigner, .spectrogram: ctx.note("Smoothed view: its marginals are blurred.")
    }
  }
}
