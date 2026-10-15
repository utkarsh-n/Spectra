import Accelerate
import XCTest
import simd

@testable import Spectra

/// The Patch graph engine (SPEC-build §5): topological order, cycle rejection, typed ports,
/// provenance union, AM/FM voice round trips (SNR), block timing, the Wigner node's marginal,
/// presets, persistence and the modulation matrix.
final class GraphTests: XCTestCase {

  // MARK: Helpers

  /// A voice-band test signal: four tones between 600 Hz and 2.2 kHz (peak < 1).
  static func voice(count: Int, start: Int) -> [Float] {
    let tones: [(Double, Double)] = [(600, 0.22), (1000, 0.2), (1500, 0.16), (2200, 0.12)]
    return (0..<count).map { k in
      let t = Double(start + k) / NodeCatalog.audioRate
      return Float(tones.reduce(0.0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t + $1.0 / 700) })
    }
  }

  /// SNR (dB) of `y` against `x` after the best integer lag (0…maxLag) and least-squares gain
  /// (vDSP dot products, so the search is quick in Debug builds too).
  static func fitSNR(reference x: [Float], received y: [Float], maxLag: Int = 2400) -> (snr: Double, lag: Int) {
    var best = (snr: -Double.infinity, lag: 0)
    let n = min(x.count, y.count) - maxLag
    guard n > 1000 else { return best }
    var xx: Float = 0
    x.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &xx, vDSP_Length(n)) }
    for lag in 0...maxLag {
      var xy: Float = 0
      var yy: Float = 0
      x.withUnsafeBufferPointer { xp in
        y.withUnsafeBufferPointer { yp in
          vDSP_dotpr(xp.baseAddress!, 1, yp.baseAddress! + lag, 1, &xy, vDSP_Length(n))
          vDSP_svesq(yp.baseAddress! + lag, 1, &yy, vDSP_Length(n))
        }
      }
      guard yy > 0 else { continue }
      let g = Double(xy) / Double(yy)
      let err = max(Double(xx) - 2 * g * Double(xy) + g * g * Double(yy), 1e-30)
      let snr = 10 * log10(Double(xx) / err)
      if snr > best.snr { best = (snr, lag) }
    }
    // The search used Float sums; measure the winning lag's residual exactly in Double.
    var xy = 0.0
    var yy = 0.0
    var xx2 = 0.0
    for k in 0..<n {
      xy += Double(x[k]) * Double(y[k + best.lag])
      yy += Double(y[k + best.lag]) * Double(y[k + best.lag])
      xx2 += Double(x[k]) * Double(x[k])
    }
    let g = yy > 0 ? xy / yy : 0
    var err = 0.0
    for k in 0..<n {
      let e = Double(x[k]) - g * Double(y[k + best.lag])
      err += e * e
    }
    best.snr = 10 * log10(xx2 / max(err, 1e-30))
    return best
  }

  /// Runs a voice through Modulator → Channel → Demodulator and returns the output SNR.
  func voiceRoundTrip(mode: String, distance: Double, txPower: Double, carrier: Double) -> (snr: Double, linkSNR: Double) {
    var g = PatchGraph()
    let mic = g.add(.stream, id: "mic")
    var mod = g.add(.modulator, id: "mod")
    mod.strings["mode"] = mode
    mod.numbers["carrier"] = carrier
    g.nodes[1] = mod
    var ch = g.add(.channel, id: "ch")
    ch.strings["environment"] = "logDistance"
    ch.numbers["distance"] = distance
    ch.numbers["txPower"] = txPower
    g.nodes[2] = ch
    _ = g.add(.demodulator, id: "demod")
    _ = g.add(.speaker, id: "out")
    XCTAssertNoThrow(try g.connect(from: PortRef(mic.id, "samples"), to: PortRef("mod", "message")))
    XCTAssertNoThrow(try g.connect(from: PortRef("mod", "signal"), to: PortRef("ch", "signal")))
    XCTAssertNoThrow(try g.connect(from: PortRef("ch", "signal"), to: PortRef("demod", "signal")))
    XCTAssertNoThrow(try g.connect(from: PortRef("demod", "audio"), to: PortRef("out", "in")))
    var ev = GraphEvaluator(graph: g)
    var sent: [Float] = []
    var heard: [Float] = []
    var link = Double.nan
    let blocks = 48
    for b in 0..<blocks {
      var world = GraphInputs.audioBlock(at: Double(b) * 1024 / 48_000)
      let x = Self.voice(count: 1024, start: b * 1024)
      sent.append(contentsOf: x)
      world.streams["mic"] = StreamInput(
        block: RealBlock(samples: x, sampleRate: 48_000, startTime: world.time), provenance: [.sim], label: "Test voice")
      let r = ev.step(world)
      for e in r.effects {
        if case .play(_, let s, let rate, _) = e {
          XCTAssertEqual(rate, 48_000, accuracy: 1e-9)
          heard.append(contentsOf: s)
        }
      }
      link = ev.value(at: PortRef("ch", "snr"))?.payload.control ?? link
    }
    // Skip the first 0.2 s of filter transients.
    let skip = 9600
    XCTAssertGreaterThan(heard.count, skip + 20_000, "\(mode): the demodulator produced too little audio")
    let fit = Self.fitSNR(reference: Array(sent[skip...]), received: Array(heard[skip...]))
    print("GraphTests \(mode) at \(distance) m: link SNR \(link) dB, voice SNR \(fit.snr) dB, lag \(fit.lag)")
    return (fit.snr, link)
  }

  // MARK: Topology

  func testTopologicalOrderPutsSourcesFirst() throws {
    var g = PatchGraph()
    let osc = g.add(.oscillator, id: "osc")
    let gain = g.add(.gain, id: "gain")
    let filter = g.add(.filter, id: "filter")
    let speaker = g.add(.speaker, id: "speaker")
    _ = g.add(.noise, id: "noise")
    // Document order is not evaluation order: wire speaker ← filter ← gain ← osc, noise alone.
    try g.connect(from: PortRef(filter.id, "out"), to: PortRef(speaker.id, "in"))
    try g.connect(from: PortRef(gain.id, "out"), to: PortRef(filter.id, "in"))
    try g.connect(from: PortRef(osc.id, "out"), to: PortRef(gain.id, "in"))
    let order = try g.topologicalOrder()
    XCTAssertEqual(Set(order), Set(g.nodes.map(\.id)))
    for c in g.cables {
      XCTAssertLessThan(order.firstIndex(of: c.from.node)!, order.firstIndex(of: c.to.node)!, "\(c.id) runs backwards")
    }
    // Ties keep document order: both sources lead.
    XCTAssertEqual(Array(order.prefix(2)), ["osc", "noise"])
    XCTAssertEqual(order.last, "speaker")
    // A pull from the speaker evaluates exactly its ancestors.
    XCTAssertEqual(g.ancestors(of: ["speaker"]), ["speaker", "filter", "gain", "osc"])
    // Gain and Filter take the type of what feeds them.
    XCTAssertEqual(g.outputTypes(PortRef("gain", "out")), [.audio])
  }

  func testCyclesAreRejected() throws {
    var g = PatchGraph()
    _ = g.add(.gain, id: "a")
    _ = g.add(.gain, id: "b")
    _ = g.add(.gain, id: "c")
    _ = g.add(.oscillator, id: "osc")
    try g.connect(from: PortRef("osc", "cv"), to: PortRef("a", "in"))
    try g.connect(from: PortRef("a", "out"), to: PortRef("b", "in"))
    try g.connect(from: PortRef("b", "out"), to: PortRef("c", "in"))
    let before = g
    XCTAssertThrowsError(try g.connect(from: PortRef("c", "out"), to: PortRef("a", "in"))) { error in
      guard case GraphError.cycle(let path) = error else { return XCTFail("expected a cycle, got \(error)") }
      XCTAssertEqual(path, ["a", "b", "c"])
    }
    XCTAssertEqual(g, before, "a rejected cable must leave the graph untouched")
    XCTAssertThrowsError(try g.connect(from: PortRef("a", "out"), to: PortRef("a", "in"))) { error in
      XCTAssertEqual(error as? GraphError, .selfLoop)
    }
    // A loop smuggled in through storage is caught by the sort and dropped by repair.
    var loop = g
    loop.cables.append(PatchCable(from: PortRef("c", "out"), to: PortRef("a", "in")))
    loop.cables.removeAll { $0.from.node == "osc" }
    XCTAssertThrowsError(try loop.topologicalOrder()) { error in
      guard case GraphError.cycle(let left) = error else { return XCTFail("expected a cycle") }
      XCTAssertEqual(Set(left), ["a", "b", "c"])
    }
    let repaired = loop.repaired()
    XCTAssertNoThrow(try repaired.topologicalOrder())
    XCTAssertEqual(repaired.cables.count, 2)
    // The evaluator still runs a graph whose cables loop (it falls back to document order).
    var ev = GraphEvaluator(graph: loop)
    _ = ev.step(GraphInputs.audioBlock(at: 0))
  }

  func testPortTypesAndDirections() throws {
    var g = PatchGraph()
    _ = g.add(.oscillator, id: "osc")
    _ = g.add(.modulator, id: "mod")
    _ = g.add(.constellation, id: "con")
    XCTAssertEqual(
      g.check(from: PortRef("osc", "out"), to: PortRef("mod", "carrier")), .typeMismatch(from: [.audio], to: [.em, .control]))
    XCTAssertEqual(g.check(from: PortRef("mod", "message"), to: PortRef("osc", "out")), .direction)
    XCTAssertEqual(g.check(from: PortRef("osc", "nope"), to: PortRef("mod", "message")), .unknownPort(PortRef("osc", "nope")))
    XCTAssertNil(g.check(from: PortRef("osc", "out"), to: PortRef("mod", "message")))
    try g.connect(from: PortRef("osc", "cv"), to: PortRef("mod", "carrier"))
    // An input takes one cable: a new cable replaces the old one.
    try g.connect(from: PortRef("osc", "out"), to: PortRef("mod", "message"))
    _ = g.add(.noise, id: "noise")
    try g.connect(from: PortRef("noise", "out"), to: PortRef("mod", "message"))
    XCTAssertEqual(g.cable(into: PortRef("mod", "message"))?.from, PortRef("noise", "out"))
    XCTAssertEqual(g.cables.count, 2)
    g.remove(node: "noise")
    XCTAssertNil(g.cable(into: PortRef("mod", "message")))
  }

  // MARK: Provenance

  func testProvenanceIsTheUnionOfInputs() throws {
    var g = PatchGraph()
    _ = g.add(.stream, id: "live")
    _ = g.add(.oscillator, id: "osc")
    _ = g.add(.mixer, id: "mix")
    _ = g.add(.gain, id: "gain")
    _ = g.add(.scope, id: "scope")
    try g.connect(from: PortRef("osc", "out"), to: PortRef("mix", "a"))
    try g.connect(from: PortRef("live", "samples"), to: PortRef("mix", "b"))
    try g.connect(from: PortRef("mix", "out"), to: PortRef("gain", "in"))
    try g.connect(from: PortRef("gain", "out"), to: PortRef("scope", "ch1"))
    var ev = GraphEvaluator(graph: g)
    var world = GraphInputs.audioBlock(at: 0)
    world.streams["live"] = StreamInput(
      block: RealBlock(samples: [Float](repeating: 0.5, count: 1024), sampleRate: 48_000, startTime: 0),
      provenance: [.live, .analogy], label: "Microphone")
    let r = ev.step(world)
    XCTAssertEqual(ev.value(at: PortRef("osc", "out"))?.provenance, [.model])
    XCTAssertEqual(ev.value(at: PortRef("live", "samples"))?.provenance, [.live, .analogy])
    XCTAssertEqual(ev.value(at: PortRef("mix", "out"))?.provenance, Provenance.union([.model, .live, .analogy]))
    XCTAssertEqual(ev.value(at: PortRef("gain", "out"))?.provenance, Provenance.union([.model, .live, .analogy]))
    // The scope channel published on the bus carries the same badges.
    let scope = r.effects.compactMap { e -> [Provenance]? in
      if case .scope(_, "ch1", _, _, let p, _) = e { return p }
      return nil
    }
    XCTAssertEqual(scope, [Provenance.union([.model, .live, .analogy])])
    // A Matter bench specimen adds its own TABLE/MODEL badge.
    var m = PatchGraph()
    _ = m.add(.spectraSource, id: "src")
    _ = m.add(.medium, id: "water")
    _ = m.add(.ruler, id: "ruler")
    try m.connect(from: PortRef("src", "wave"), to: PortRef("water", "wave"))
    try m.connect(from: PortRef("water", "wave"), to: PortRef("ruler", "in"))
    var mev = GraphEvaluator(graph: m)
    _ = mev.step(GraphInputs(time: 0, dt: 1.0 / 60))
    let water = SpecimenKey.water.evaluate(550e-9)
    let badge = Provenance(rawValue: water.source.rawValue)!
    XCTAssertEqual(mev.value(at: PortRef("water", "wave"))?.provenance, Provenance.union([.model, badge]))
    XCTAssertEqual(mev.value(at: PortRef("water", "transmission"))?.payload.control ?? -1, water.transmission ?? -2, accuracy: 1e-12)
  }

  // MARK: Voice round trips

  func testAMVoiceRoundTripSNR() {
    let clean = voiceRoundTrip(mode: "am", distance: 100, txPower: 36, carrier: 27.185e6)
    XCTAssertGreaterThan(clean.linkSNR, 60)
    XCTAssertGreaterThan(clean.snr, 25, "AM envelope detection should return the voice nearly intact")
    // The preset's 30 km at 36 dBm (log-distance n = 3) leaves about 28 dB in 10 kHz: audible hiss.
    let preset = voiceRoundTrip(mode: "am", distance: 30_000, txPower: 36, carrier: 27.185e6)
    XCTAssertEqual(preset.linkSNR, 27.5, accuracy: 1.5)
    XCTAssertLessThan(preset.snr, clean.snr - 3, "noise must reach the voice")
    XCTAssertGreaterThan(preset.snr, 8, "but the voice is still there")
    // Ten times farther the carrier sinks below the noise.
    let far = voiceRoundTrip(mode: "am", distance: 300_000, txPower: 36, carrier: 27.185e6)
    XCTAssertLessThan(far.linkSNR, 0)
    XCTAssertLessThan(far.snr, 3)
  }

  func testFMVoiceRoundTripSNR() {
    let clean = voiceRoundTrip(mode: "fm", distance: 50, txPower: 27, carrier: 462.6e6)
    XCTAssertGreaterThan(clean.linkSNR, 50)
    XCTAssertGreaterThan(clean.snr, 25, "the FM discriminator should return the voice nearly intact")
    // The preset's 2 km: about 27 dB in the 18 kHz Carson band, above the ~10 dB threshold.
    let preset = voiceRoundTrip(mode: "fm", distance: 2000, txPower: 27, carrier: 462.6e6)
    XCTAssertEqual(preset.linkSNR, 26.6, accuracy: 1.5)
    XCTAssertGreaterThan(preset.snr, 15, "above threshold FM keeps the voice clean")
    // Below the threshold the voice breaks up.
    let far = voiceRoundTrip(mode: "fm", distance: 20_000, txPower: 27, carrier: 462.6e6)
    XCTAssertLessThan(far.linkSNR, 12)
    XCTAssertLessThan(far.snr, 10)
  }

  func testDigitalTextRoundTrip() throws {
    var g = PatchGraph()
    var bits = g.add(.bits, id: "bits")
    bits.strings["text"] = "Spectra patch"
    bits.strings["block"] = "1024"
    g.nodes[0] = bits
    var mod = g.add(.modulator, id: "mod")
    mod.strings["mode"] = "qpsk"
    g.nodes[1] = mod
    var ch = g.add(.channel, id: "ch")
    ch.numbers["distance"] = 1
    g.nodes[2] = ch
    _ = g.add(.demodulator, id: "demod")
    _ = g.add(.constellation, id: "con")
    try g.connect(from: PortRef("bits", "bits"), to: PortRef("mod", "message"))
    try g.connect(from: PortRef("mod", "signal"), to: PortRef("ch", "signal"))
    try g.connect(from: PortRef("ch", "signal"), to: PortRef("demod", "signal"))
    try g.connect(from: PortRef("demod", "symbols"), to: PortRef("con", "in"))
    var ev = GraphEvaluator(graph: g)
    for k in 0..<12 { _ = ev.step(GraphInputs(time: Double(k) / 60, dt: 1.0 / 60)) }
    let text = ev.value(at: PortRef("demod", "bits"))?.payload.bits?.text ?? ""
    XCTAssertTrue(text.contains("Spectra patch"), "received: \(text)")
    XCTAssertEqual(ev.value(at: PortRef("demod", "ber"))?.payload.control ?? 1, 0, accuracy: 1e-12)
    XCTAssertLessThan(ev.value(at: PortRef("demod", "evm"))?.payload.control ?? 100, 2)
    let symbols = ev.value(into: PortRef("con", "in"))?.payload.iqBlock
    XCTAssertEqual(symbols?.isSymbols, true)
    XCTAssertEqual(symbols?.ideal.count, 4)
  }

  func testMuLawRoundTrip() {
    for x in stride(from: -1.0, through: 1.0, by: 0.01) {
      let y = Double(MuLaw.decode(MuLaw.encode(Float(x))))
      // 8-bit µ-law: relative error within a few percent above −40 dB, absolute below.
      XCTAssertEqual(y, x, accuracy: max(0.002, abs(x) * 0.04))
    }
    XCTAssertEqual(MuLaw.bits([0b1010_0001]), [1, 0, 1, 0, 0, 0, 0, 1])
  }

  // MARK: Timing

  func testBlockTiming() {
    var s = BlockScheduler()
    XCTAssertEqual(s.blockDuration, 1024.0 / 48_000, accuracy: 1e-15)
    XCTAssertEqual(s.due(at: 100), [], "the first tick only starts the clock")
    var all: [Double] = []
    var t = 100.0
    for _ in 0..<600 {
      t += 1.0 / 60
      let d = s.due(at: t)
      XCTAssertLessThanOrEqual(d.count, 2, "a 60 Hz display never needs more than two blocks a frame")
      all.append(contentsOf: d)
    }
    // 10 s at 46.875 blocks per second.
    XCTAssertEqual(Double(all.count), 468.75, accuracy: 1)
    for k in 1..<all.count {
      XCTAssertEqual(all[k] - all[k - 1], 1024.0 / 48_000, accuracy: 1e-9, "blocks must be contiguous")
    }
    // A 2 s stall does not burst: at most maxPerTick blocks, then the backlog is dropped.
    let burst = s.due(at: t + 2)
    XCTAssertEqual(burst.count, s.maxPerTick)
    XCTAssertLessThanOrEqual(s.due(at: t + 2 + 1.0 / 60).count, 1)

    // An audio-rate graph steps in exact 1024-sample blocks at 48 kHz.
    let g = PatchPreset.voiceFM.graph
    XCTAssertTrue(g.isAudioRate)
    XCTAssertFalse(PatchPreset.wifiOFDM.graph.isAudioRate)
    var og = PatchGraph()
    _ = og.add(.oscillator, id: "osc")
    var ev = GraphEvaluator(graph: og)
    for (k, start) in all.prefix(5).enumerated() {
      _ = ev.step(GraphInputs.audioBlock(at: start))
      let b = ev.value(at: PortRef("osc", "out"))?.payload.audio
      XCTAssertEqual(b?.count, NodeCatalog.blockSize)
      XCTAssertEqual(b?.sampleRate, NodeCatalog.audioRate)
      XCTAssertEqual(b?.startTime ?? -1, start, accuracy: 1e-12, "block \(k)")
    }
    // Phase continuity across blocks: a 1 kHz sine has no seam.
    var sine = PatchGraph()
    var osc = sine.add(.oscillator, id: "osc")
    osc.numbers["f"] = 1000
    osc.numbers["amp"] = 1
    sine.nodes[0] = osc
    var sev = GraphEvaluator(graph: sine)
    var joined: [Float] = []
    for k in 0..<3 {
      _ = sev.step(GraphInputs.audioBlock(at: Double(k) * s.blockDuration))
      joined.append(contentsOf: sev.value(at: PortRef("osc", "out"))?.payload.audio?.samples ?? [])
    }
    for k in joined.indices {
      XCTAssertEqual(Double(joined[k]), sin(2 * .pi * 1000 * Double(k) / 48_000), accuracy: 1e-4)
    }
  }

  func testVoiceGraphRunsInRealTime() {
    var ev = GraphEvaluator(graph: PatchPreset.voiceFM.graph)
    let mic = PatchPreset.voiceFM.graph.nodes.first { $0.kind == .stream }!.id
    var total = 0.0
    let n = 30
    for b in 0..<n {
      var world = GraphInputs.audioBlock(at: Double(b) * 1024 / 48_000)
      world.streams[mic] = StreamInput(
        block: RealBlock(samples: Self.voice(count: 1024, start: b * 1024), sampleRate: 48_000, startTime: world.time),
        provenance: [.sim], label: "Test voice")
      total += ev.step(world).duration
    }
    let perBlock = total / Double(n)
    // One block is 21.3 ms of sound; the graph must compute it in less (Debug builds included).
    XCTAssertLessThan(perBlock, 1024.0 / 48_000, "per-block CPU \(perBlock * 1000) ms")
  }

  // MARK: Phase engine nodes

  func testWignerNodeMarginal() throws {
    var g = PatchGraph()
    var osc = g.add(.oscillator, id: "osc")
    osc.numbers["f"] = 3000
    osc.numbers["amp"] = 0.8
    g.nodes[0] = osc
    var w = g.add(.wigner, id: "w")
    w.strings["length"] = "1024"
    w.strings["mode"] = "wignerVille"
    g.nodes[1] = w
    _ = g.add(.marginal, id: "m")
    _ = g.add(.spectrum, id: "view")
    try g.connect(from: PortRef("osc", "out"), to: PortRef("w", "in"))
    try g.connect(from: PortRef("w", "image"), to: PortRef("m", "image"))
    try g.connect(from: PortRef("m", "frequency"), to: PortRef("view", "in"))
    var ev = GraphEvaluator(graph: g)
    for k in 0..<4 { _ = ev.step(GraphInputs.audioBlock(at: Double(k) * 1024 / 48_000)) }
    let image = try XCTUnwrap(ev.value(at: PortRef("w", "image"))?.payload.image)
    XCTAssertEqual(image.mode, .wignerVille)
    XCTAssertEqual(image.sampleRate, 48_000)
    XCTAssertEqual(image.image.plane.rows, 128)
    // M1: Σ_ν W dν = |z(t)|² at every row, exact for the unsmoothed Wigner.
    let error = try XCTUnwrap(ev.value(at: PortRef("m", "error"))?.payload.control)
    XCTAssertLessThan(error, 1e-9)
    XCTAssertEqual(error, MarginalProcessor.timeMarginalError(image.image), accuracy: 1e-15)
    // The frequency marginal peaks at the tone.
    let f = try XCTUnwrap(ev.value(at: PortRef("m", "frequency"))?.payload.spectrum)
    XCTAssertFalse(f.isDB)
    let k = f.values.indices.max { f.values[$0] < f.values[$1] }!
    XCTAssertEqual(f.startFrequency + Double(k) * f.binWidth, 3000, accuracy: 2 * f.binWidth)
    // The time marginal is a block on the record's own time axis.
    let tm = try XCTUnwrap(ev.value(at: PortRef("m", "time"))?.payload.audio)
    XCTAssertEqual(tm.count, 128)
    // Smoothed views are flagged, not called errors.
    var gs = g
    gs.nodes[1].strings["mode"] = "spectrogram"
    ev.load(gs)
    _ = ev.step(GraphInputs.audioBlock(at: 1))
    XCTAssertEqual(ev.statuses["m"]?.text, "Smoothed view: its marginals are blurred.")
  }

  /// A 100 Hz sensor arrives two samples per step with a slightly jittering measured rate:
  /// the FFT must keep accumulating (not restart) and find the 60 Hz mains alias at 39.8 Hz.
  func testSensorRateFFTAccumulatesAcrossBlocks() throws {
    var g = PatchGraph()
    _ = g.add(.stream, id: "mag")
    var fft = g.add(.fft, id: "fft")
    fft.strings["size"] = "256"
    fft.numbers["average"] = 0
    g.nodes[1] = fft
    _ = g.add(.spectrum, id: "view")
    try g.connect(from: PortRef("mag", "samples"), to: PortRef("fft", "in"))
    try g.connect(from: PortRef("fft", "spectrum"), to: PortRef("view", "in"))
    var ev = GraphEvaluator(graph: g)
    let fs = 99.8
    var k = 0
    for step in 0..<150 {
      let x: [Float] = (0..<2).map { j in Float(1.6 * sin(2 * .pi * 60 * Double(k + j) / fs)) }
      k += 2
      var world = GraphInputs(time: Double(step) / 50, dt: 1.0 / 50)
      let jitter = step % 2 == 0 ? 1.004 : 0.996
      world.streams["mag"] = StreamInput(
        block: RealBlock(samples: x, sampleRate: fs * jitter, startTime: world.time, unit: "µT"), provenance: [.sim], label: "|B|")
      _ = ev.step(world)
    }
    XCTAssertNil(ev.statuses["fft"].flatMap { $0.text.hasPrefix("Collecting") ? $0 : nil }, "the record should be full")
    let peak = try XCTUnwrap(ev.value(at: PortRef("fft", "peak"))?.payload.control)
    XCTAssertEqual(peak, 39.8, accuracy: fs / 256 * 1.5, "60 Hz aliases to fs − 60 = 39.8 Hz")
  }

  // MARK: Spin engine nodes

  func testEarthFieldNMRNode() throws {
    let preset = PatchPreset.earthNMR
    var ev = GraphEvaluator(graph: preset.graph)
    let mag = preset.graph.nodes.first { $0.kind == .stream }!.id
    var ruler: Double?
    for b in 0..<24 {
      var world = GraphInputs.audioBlock(at: Double(b) * 1024 / 48_000)
      world.streams[mag] = StreamInput(
        block: RealBlock(samples: [50, 50], sampleRate: 100, startTime: world.time, unit: "µT"), provenance: [.live],
        label: "|B|")
      for e in ev.step(world).effects {
        if case .ruler(_, let lambda, _, let p) = e {
          ruler = lambda
          XCTAssertTrue(p.contains(.live), "the Larmor marker carries LIVE |B|")
        }
      }
    }
    let fid = preset.graph.nodes.first { $0.kind == .spinFID }!.id
    let larmor = try XCTUnwrap(ev.value(at: PortRef(fid, "larmor"))?.payload.control)
    XCTAssertEqual(larmor, SpinSpecies.protonWater.larmorHz(field: 50e-6), accuracy: 1e-6)
    XCTAssertEqual(larmor, 2128.8192715, accuracy: 1e-4)
    XCTAssertEqual(try XCTUnwrap(ruler), SpectrumMarker.lambda(forFrequency: larmor), accuracy: 1e-6)
    let fft = preset.graph.nodes.first { $0.kind == .fft }!.id
    let peak = try XCTUnwrap(ev.value(at: PortRef(fft, "peak"))?.payload.control)
    XCTAssertEqual(peak, larmor, accuracy: 48_000.0 / 8192 * 1.5)
  }

  // MARK: Presets, persistence, modulation

  func testPresetsBuildAndRun() throws {
    XCTAssertEqual(PatchPreset.all.count, 8)
    XCTAssertEqual(Set(PatchPreset.all.map(\.id)).count, 8)
    for p in PatchPreset.all {
      XCTAssertEqual(p.problems, [], p.id)
      XCTAssertNoThrow(try p.graph.topologicalOrder(), p.id)
      XCTAssertEqual(p.graph.repaired(), p.graph, "\(p.id) is already well formed")
      var ev = GraphEvaluator(graph: p.graph)
      for b in 0..<6 {
        var world = GraphInputs.audioBlock(at: Double(b) * 1024 / 48_000)
        world.attitude = simd_quatd(angle: 0.3, axis: SIMD3(0, 0, 1))
        for n in p.graph.nodes where n.kind == .stream {
          let rate = n.string("stream").hasPrefix("mic.") ? 48_000.0 : 100
          world.streams[n.id] = StreamInput(
            block: RealBlock(
              samples: Self.voice(count: rate > 1000 ? 1024 : 2, start: b * 1024).map { $0 + 50 }, sampleRate: rate,
              startTime: world.time),
            provenance: [.sim], label: n.title)
        }
        _ = ev.step(world)
      }
      for (id, s) in ev.statuses where s.level == .warning {
        XCTFail("\(p.id): node \(id) warns: \(s.text)")
      }
    }
  }

  func testDocumentRoundTripAndTolerantDecoding() throws {
    let g = PatchPreset.gyroArray.graph
    let data = try JSONEncoder().encode(g)
    XCTAssertEqual(try JSONDecoder().decode(PatchGraph.self, from: data), g)
    // Missing parameter dictionaries and positions fall back to the catalogue.
    let json = #"{"nodes":[{"id":"n1","kind":"oscillator"}],"cables":[]}"#
    let d = try JSONDecoder().decode(PatchGraph.self, from: Data(json.utf8))
    XCTAssertEqual(d.nodes.first?.number("f"), 440)
    XCTAssertEqual(d.nodes.first?.string("wave"), "sine")
    XCTAssertEqual(d.nodes.first?.x, 0)
  }

  func testKnobTargetModulatesInPositionSpace() throws {
    var g = PatchGraph()
    var lfo = g.add(.oscillator, id: "lfo")
    lfo.numbers["f"] = 0.25
    lfo.numbers["amp"] = 1
    lfo.strings["wave"] = "square"
    g.nodes[0] = lfo
    _ = g.add(.oscillator, id: "tone")
    var knob = g.add(.knob, id: "knob")
    knob.strings["target"] = "tone.f"
    knob.numbers["depth"] = 0.25
    g.nodes[2] = knob
    try g.connect(from: PortRef("lfo", "cv"), to: PortRef("knob", "cv"))
    var ev = GraphEvaluator(graph: g)
    _ = ev.step(GraphInputs.audioBlock(at: 0))
    let drive = try XCTUnwrap(ev.drives["tone.f"])
    XCTAssertEqual(drive.cv, 1, accuracy: 1e-12)
    XCTAssertEqual(drive.source, "Oscillator")
    // The tone's frequency knob moves a quarter of its (log) sweep: 440 Hz × (20 000/0.05)^0.25.
    let node = ev.graph.node("tone")!
    let ctx = NodeContext(node: node, inputs: [:], world: GraphInputs.audioBlock(at: 0), drives: ["f": drive])
    let scale = try XCTUnwrap(node.spec.param("f")?.scale)
    XCTAssertEqual(ctx.number("f"), scale.value(at: scale.position(of: 440) + 0.25), accuracy: 1e-9)
    XCTAssertEqual(ctx.number("f"), 440 * pow(20_000 / 0.05, 0.25), accuracy: 1e-6)
    // Removing the knob node removes its drive.
    g.remove(node: "knob")
    ev.load(g)
    _ = ev.step(GraphInputs.audioBlock(at: 1))
    XCTAssertNil(ev.drives["tone.f"])
  }

  // MARK: Review fixes

  /// The Motion node's angles are Core Motion's (R = Rz(yaw)·Rx(pitch)·Ry(roll)), the
  /// convention of the `attitude.*` streams the model builds the quaternion from: a pure
  /// pitch must come back as pitch, not roll.
  func testMotionAnglesMatchCoreMotionConvention() {
    let d = Double.pi / 180
    func quat(yaw: Double, pitch: Double, roll: Double) -> simd_quatd {
      simd_quatd(angle: yaw * d, axis: SIMD3(0, 0, 1)) * simd_quatd(angle: pitch * d, axis: SIMD3(1, 0, 0))
        * simd_quatd(angle: roll * d, axis: SIMD3(0, 1, 0))
    }
    let pure = MotionProcessor.angles(quat(yaw: 0, pitch: 30, roll: 0))
    XCTAssertEqual(pure.pitch, 30, accuracy: 1e-9)
    XCTAssertEqual(pure.roll, 0, accuracy: 1e-9)
    XCTAssertEqual(pure.yaw, 0, accuracy: 1e-9)
    for (y, p, r) in [(40.0, -25.0, 70.0), (-120.0, 60.0, -150.0), (170.0, 10.0, 5.0), (0.0, -80.0, 100.0)] {
      let a = MotionProcessor.angles(quat(yaw: y, pitch: p, roll: r))
      XCTAssertEqual(a.yaw, y, accuracy: 1e-9, "yaw of (\(y), \(p), \(r))")
      XCTAssertEqual(a.pitch, p, accuracy: 1e-9, "pitch of (\(y), \(p), \(r))")
      XCTAssertEqual(a.roll, r, accuracy: 1e-9, "roll of (\(y), \(p), \(r))")
    }
  }

  /// A control cable on a Scope declares one steady rate however much the frame time jitters
  /// (a moving declared rate made the model re-register the stream and lose its history).
  func testScopeControlChannelDeclaresSteadyRate() throws {
    var g = PatchGraph()
    _ = g.add(.stream, id: "baro")
    _ = g.add(.scope, id: "scope")
    try g.connect(from: PortRef("baro", "value"), to: PortRef("scope", "ch1"))
    var ev = GraphEvaluator(graph: g)
    var rates: [Double] = []
    var times: [Double] = []
    var t = 10.0
    for dt in [0.011, 0.016, 0.034, 0.012, 0.05, 0.1] {
      t += dt
      var world = GraphInputs(time: t, dt: dt)
      world.streams["baro"] = StreamInput(
        block: RealBlock(samples: [101_325], sampleRate: 1, startTime: t, unit: "Pa"), provenance: [.sim], label: "Pressure")
      for e in ev.step(world).effects {
        if case .scope(_, "ch1", let b, _, _, _) = e {
          rates.append(b.sampleRate)
          times.append(b.startTime)
        }
      }
    }
    XCTAssertEqual(rates.count, 6)
    XCTAssertEqual(Set(rates), [60], "frame-rate graphs declare a nominal 60 Hz")
    XCTAssertEqual(times, times.sorted(), "each value keeps its own step time")
    XCTAssertEqual(SinkProcessor.controlRate(GraphInputs.audioBlock(at: 0)), 46.875, accuracy: 1e-12)
  }

  /// Edits after `load` reach the next step (the evaluator precomputes its cable tables).
  func testEvaluatorFollowsEditsAfterLoad() throws {
    var g = PatchGraph()
    var osc = g.add(.oscillator, id: "osc")
    osc.numbers["f"] = 2
    osc.numbers["amp"] = 1
    osc.strings["wave"] = "square"
    g.nodes[0] = osc
    _ = g.add(.oscillator, id: "tone")
    var knob = g.add(.knob, id: "knob")
    knob.strings["target"] = "tone.amp"
    g.nodes[2] = knob
    var ev = GraphEvaluator(graph: g)
    _ = ev.step(GraphInputs.audioBlock(at: 0))
    XCTAssertNil(ev.drives["tone.amp"], "no cable into CV yet")
    try g.connect(from: PortRef("osc", "cv"), to: PortRef("knob", "cv"))
    g.nodes[0].label = "Wobble"
    ev.load(g)
    _ = ev.step(GraphInputs.audioBlock(at: 1))
    XCTAssertEqual(ev.drives["tone.amp"]?.source, "Wobble", "the new cable and the source's new title are used")
    g.disconnect(input: PortRef("knob", "cv"))
    ev.load(g)
    _ = ev.step(GraphInputs.audioBlock(at: 2))
    XCTAssertNil(ev.drives["tone.amp"])
  }

  /// The off-main runner steps exactly like the evaluator: loads before steps, a reset first,
  /// per-step samples, and a snapshot the views read.
  func testRunnerMatchesEvaluator() async throws {
    let g = PatchPreset.earthNMR.graph
    let mag = g.nodes.first { $0.kind == .stream }!.id
    let fid = g.nodes.first { $0.kind == .spinFID }!.id
    func worlds(_ range: Range<Int>) -> [GraphInputs] {
      range.map { b in
        var w = GraphInputs.audioBlock(at: Double(b) * 1024 / 48_000)
        w.streams[mag] = StreamInput(
          block: RealBlock(samples: [50, 50], sampleRate: 100, startTime: w.time, unit: "µT"), provenance: [.live], label: "|B|")
        return w
      }
    }
    var direct = GraphEvaluator(graph: g)
    var effects = 0
    for w in worlds(0..<6) { effects += direct.step(w).effects.count }
    let runner = GraphRunner(graph: PatchGraph())
    let reply = await runner.run(
      GraphRequest(
        reset: true, load: g, worlds: worlds(0..<6),
        samples: ["larmor": GraphSample(ref: PortRef(fid, "larmor"), viaInput: false)]))
    XCTAssertEqual(reply.steps.count, 6)
    XCTAssertEqual(reply.steps.map(\.effects.count).reduce(0, +), effects)
    XCTAssertEqual(reply.steps.map(\.time), worlds(0..<6).map(\.time))
    let larmor = try XCTUnwrap(reply.snapshot.value(at: PortRef(fid, "larmor"))?.payload.control)
    XCTAssertEqual(larmor, try XCTUnwrap(direct.value(at: PortRef(fid, "larmor"))?.payload.control), accuracy: 1e-9)
    XCTAssertEqual(reply.steps.last?.samples["larmor"]?.payload.control ?? 0, larmor, accuracy: 1e-9)
    XCTAssertEqual(reply.snapshot.statuses, direct.statuses)
    XCTAssertEqual(reply.snapshot.active, direct.active)
    XCTAssertEqual(GraphEvaluator.activeNodes(in: g), direct.active)
    // A load alone steps nothing but re-resolves cables.
    var edited = g
    edited.disconnect(input: PortRef(fid, "field"))
    let loaded = await runner.run(GraphRequest(load: edited))
    XCTAssertTrue(loaded.steps.isEmpty)
    XCTAssertNil(loaded.snapshot.value(into: PortRef(fid, "field")))
  }

  /// An Antenna with nothing to transmit is a receive antenna: its gain still flows (into a
  /// Channel's Rx gain), and it does not ask for a signal it does not need.
  func testReceiveAntennaFeedsChannelRxGain() throws {
    var g = PatchGraph()
    _ = g.add(.bits, id: "bits")
    var mod = g.add(.modulator, id: "mod")
    mod.strings["mode"] = "qpsk"
    mod.numbers["carrier"] = 28e9
    g.nodes[1] = mod
    var rx = g.add(.antenna, id: "rx")
    rx.strings["style"] = "phasedArray"
    g.nodes[2] = rx
    _ = g.add(.channel, id: "ch")
    _ = g.add(.constellation, id: "con")
    _ = g.add(.demodulator, id: "demod")
    try g.connect(from: PortRef("bits", "bits"), to: PortRef("mod", "message"))
    try g.connect(from: PortRef("mod", "signal"), to: PortRef("ch", "signal"))
    try g.connect(from: PortRef("rx", "gain"), to: PortRef("ch", "rxGain"))
    try g.connect(from: PortRef("ch", "signal"), to: PortRef("demod", "signal"))
    try g.connect(from: PortRef("demod", "symbols"), to: PortRef("con", "in"))
    var ev = GraphEvaluator(graph: g)
    for k in 0..<4 { _ = ev.step(GraphInputs(time: Double(k) / 60, dt: 1.0 / 60)) }
    let gain = try XCTUnwrap(ev.value(at: PortRef("rx", "gain"))?.payload.control)
    XCTAssertGreaterThan(gain, 5, "an 8-element array at broadside has gain")
    XCTAssertEqual(ev.statuses["rx"]?.level, .info)
    // The link budget counts the receive gain: the same link without it has less SNR.
    let withRx = try XCTUnwrap(ev.value(at: PortRef("ch", "snr"))?.payload.control)
    g.disconnect(input: PortRef("ch", "rxGain"))
    var plain = GraphEvaluator(graph: g)
    for k in 0..<4 { _ = plain.step(GraphInputs(time: Double(k) / 60, dt: 1.0 / 60)) }
    let without = try XCTUnwrap(plain.value(at: PortRef("ch", "snr"))?.payload.control)
    XCTAssertEqual(withRx - without, gain, accuracy: 1e-6)
  }

  /// "Add to Patch" of Radio I/Q or Spin FID: a Live stream with a quadrature partner comes
  /// out as one I/Q block, paired by timestamp (a late or missing Q sample is not misaligned).
  func testStreamNodePairsQuadraturePartner() throws {
    XCTAssertEqual(StreamInput.quadraturePartner(of: "radio.i"), "radio.q")
    XCTAssertEqual(StreamInput.quadraturePartner(of: "gyro.tip.i"), "gyro.tip.q")
    XCTAssertEqual(StreamInput.quadraturePartner(of: "spin.fid"), "spin.fid.q")
    XCTAssertNil(StreamInput.quadraturePartner(of: "spin.fid.q"))
    XCTAssertNil(StreamInput.quadraturePartner(of: "ble.*"))
    let rate = 2400.0
    let t = (0..<12).map { 5 + Double($0) / rate }
    let i = t.map { Float(cos(2 * .pi * 300 * $0)) }
    var qt = t
    qt.remove(at: 4)  // one Q sample missing
    qt.append(5 + 12 / rate)  // and one Q sample ahead of I
    let q = qt.map { Float(sin(2 * .pi * 300 * $0)) }
    let p = StreamInput.pair(i: i, iTimes: t, q: q, qTimes: qt, tolerance: 0.25 / rate)
    XCTAssertEqual(p.times.count, 11)
    XCTAssertFalse(p.times.contains(t[4]))
    for k in p.times.indices {
      // Each pair is one sample of the same phasor: |I + jQ| = 1.
      XCTAssertEqual(Double(p.i[k] * p.i[k] + p.q[k] * p.q[k]), 1, accuracy: 1e-5)
    }

    var g = PatchGraph()
    _ = g.add(.stream, id: "radio")
    _ = g.add(.constellation, id: "con")
    try g.connect(from: PortRef("radio", "iq"), to: PortRef("con", "in"))
    var ev = GraphEvaluator(graph: g)
    var world = GraphInputs(time: 5, dt: 1.0 / 60)
    let carrier = 2.44e9
    world.streams["radio"] = StreamInput(
      block: RealBlock(samples: i, sampleRate: rate, startTime: t[0], unit: "V"), provenance: [.model], label: "Radio I",
      lambda: SpectrumMarker.lambda(forFrequency: carrier),
      iq: IQBlock(
        iq: RF.IQBuffer(i: p.i, q: p.q), sampleRate: rate, startTime: p.times[0], carrierHz: carrier))
    _ = ev.step(world)
    let out = try XCTUnwrap(ev.value(at: PortRef("radio", "iq")))
    XCTAssertEqual(out.type, .iq)
    XCTAssertEqual(out.payload.iqBlock?.count, 11)
    XCTAssertEqual(out.payload.iqBlock?.carrierHz ?? 0, carrier, accuracy: 1)
    XCTAssertTrue(out.provenance.contains(.model))
    // Without a partner the cabled I/Q output says why instead of sitting dark.
    world.streams["radio"]?.iq = nil
    _ = ev.step(world)
    XCTAssertTrue(ev.statuses["radio"]?.text.contains("quadrature") ?? false)
  }

  func testDigitalVoiceOverQPSK() throws {
    var g = PatchGraph()
    _ = g.add(.stream, id: "mic")
    var mod = g.add(.modulator, id: "mod")
    mod.strings["mode"] = "qpsk"
    mod.numbers["symbolRate"] = 64_000
    g.nodes[1] = mod
    _ = g.add(.demodulator, id: "demod")
    _ = g.add(.speaker, id: "out")
    try g.connect(from: PortRef("mic", "samples"), to: PortRef("mod", "message"))
    try g.connect(from: PortRef("mod", "signal"), to: PortRef("demod", "signal"))
    try g.connect(from: PortRef("demod", "audio"), to: PortRef("out", "in"))
    var ev = GraphEvaluator(graph: g)
    var sent: [Float] = []
    var heard: [Float] = []
    for b in 0..<40 {
      var world = GraphInputs.audioBlock(at: Double(b) * 1024 / 48_000)
      let x = Self.voice(count: 1024, start: b * 1024)
      sent.append(contentsOf: x)
      world.streams["mic"] = StreamInput(
        block: RealBlock(samples: x, sampleRate: 48_000, startTime: world.time), provenance: [.sim], label: "Voice")
      for e in ev.step(world).effects {
        if case .play(_, let s, _, _) = e { heard.append(contentsOf: s) }
      }
    }
    XCTAssertEqual(ev.value(at: PortRef("demod", "ber"))?.payload.control ?? 1, 0, accuracy: 1e-12)
    // 8-bit µ-law at 8 kHz keeps a voice-band signal to roughly 30 dB.
    let fit = Self.fitSNR(reference: Array(sent[9600...]), received: Array(heard[min(9600, heard.count)...]), maxLag: 3000)
    print("GraphTests µ-law QPSK voice SNR \(fit.snr) dB, lag \(fit.lag)")
    XCTAssertGreaterThan(fit.snr, 20)
  }

  // MARK: Review: the presets' layouts

  /// No preset cable may run hidden behind a card it does not plug into (a Wigner → picture
  /// cable ran 71 % of its length behind the starter's Marginal card and looked like the
  /// Marginal's output; the voice presets' microphone → CH2 cable ran behind the Modulator),
  /// nor brush past another cabled port (the BLE model's cable hooked into CH2 beside the live
  /// RSSI's Value port, and read as its cable), and no two unrelated cabled ports may face each
  /// other across a gap. Cables are the canvas's Béziers (`PatchCanvasView.cablePath` at zoom 1);
  /// a backward cable may curl behind its own ends.
  func testPresetCablesRunClearOfCards() throws {
    for preset in PatchPreset.all {
      try assertCablesRunClear(preset.graph, preset.id)
    }
  }

  func assertCablesRunClear(_ g: PatchGraph, _ name: String) throws {
    func rect(_ n: PatchNode) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
      (n.x, n.y, n.x + PatchGeometry.cardWidth, n.y + PatchGeometry.height(of: n.kind))
    }
    // Every port with a cable, where it sits on the canvas.
    var plugged: [(ref: PortRef, isInput: Bool, at: SIMD2<Double>)] = []
    for c in g.cables {
      for (ref, isInput) in [(c.from, false), (c.to, true)] where !plugged.contains(where: { $0.ref == ref && $0.isInput == isInput }) {
        let n = try XCTUnwrap(g.node(ref.node))
        let o = try XCTUnwrap(PatchGeometry.portOffset(kind: n.kind, port: ref.port, isInput: isInput))
        plugged.append((ref, isInput, SIMD2(n.x + o.x, n.y + o.y)))
      }
    }
    for c in g.cables {
      let a = try XCTUnwrap(g.node(c.from.node))
      let b = try XCTUnwrap(g.node(c.to.node))
      let oa = try XCTUnwrap(PatchGeometry.portOffset(kind: a.kind, port: c.from.port, isInput: false))
      let ob = try XCTUnwrap(PatchGeometry.portOffset(kind: b.kind, port: c.to.port, isInput: true))
      let p0 = SIMD2(a.x + oa.x, a.y + oa.y)
      let p3 = SIMD2(b.x + ob.x, b.y + ob.y)
      let (p1, p2) = PatchGeometry.cableControls(from: p0, to: p3)
      var hidden = 0
      var samples = 0
      var brushes: Set<String> = []
      for k in 1..<100 {
        let t = Double(k) / 100
        let u = 1 - t
        let q = u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
        samples += 1
        // Inside a third card (8 pt inside its edge).
        if g.nodes.contains(where: { n in
          guard n.id != a.id, n.id != b.id else { return false }
          let r = rect(n)
          return q.x > r.x0 + 8 && q.x < r.x1 - 8 && q.y > r.y0 + 8 && q.y < r.y1 - 8
        }) { hidden += 1 }
        // Within 12 pt of another cabled port: it would read as that port's cable.
        for p in plugged where !(p.ref == c.from && !p.isInput) && !(p.ref == c.to && p.isInput) {
          if simd_distance(q, p.at) < 12 { brushes.insert(p.ref.description) }
        }
      }
      XCTAssert(brushes.isEmpty, "\(name): cable \(c.id) brushes past the cabled port(s) \(brushes.sorted())")
      XCTAssertLessThan(
        Double(hidden) / Double(samples), 0.05, "\(name): cable \(c.id) runs behind another card for \(hidden) % of its length")
    }
    // A cabled output facing a cabled input across a gap at the same height reads as one cable
    // unless it is one (the Wi-Fi Modulator's Signal faced the Demodulator's).
    let wired = Set(g.cables.map { "\($0.from)>\($0.to)" })
    for o in plugged where !o.isInput {
      for i in plugged where i.isInput && i.ref.node != o.ref.node {
        let facing = abs(i.at.y - o.at.y) < 14 && i.at.x > o.at.x && i.at.x - o.at.x < 60
        XCTAssertFalse(
          facing && !wired.contains("\(o.ref)>\(i.ref)"), "\(name): \(o.ref) faces \(i.ref) across a gap but they are not cabled")
      }
    }
  }

  #if canImport(UIKit)
  // MARK: Review: the model's scope taps, waterfalls and markers

  /// "Open in Scope" on a node that is not a Scope publishes every step's block, not just the
  /// last step of a reply (a reply that caught up three blocks left two 21 ms holes), and a
  /// Spectrum sink's waterfall takes a row per new spectrum, not per refresh.
  @MainActor
  func testOpenInScopeKeepsEveryBlockAndWaterfallRowsFollowSpectra() async throws {
    let name = "Spectra.graphtests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    let app = AppModel(launch: LaunchOptions(arguments: ["Spectra", "-ui-testing"]), defaults: UserDefaults(suiteName: name)!)
    let model = app.patch
    model.clear()
    let osc = model.addNode(.oscillator, at: .zero)
    let fft = model.addNode(.fft, at: CGPoint(x: 212, y: 0))
    let sink = model.addNode(.spectrum, at: CGPoint(x: 424, y: 0))
    XCTAssertNil(model.connect(from: PortRef(osc, "out"), to: PortRef(fft, "in")))
    XCTAssertNil(model.connect(from: PortRef(fft, "spectrum"), to: PortRef(sink, "in")))
    model.setVisible(true)
    app.clock.playing = true
    let block = Double(NodeCatalog.blockSize) / NodeCatalog.audioRate
    // The signal clock: previews compare tick times with their own last refresh.
    var now = SignalClock.now() + 1
    func settle() async throws {
      for _ in 0..<40 { try await Task.sleep(for: .milliseconds(15)) }
    }
    model.tick(now: now)  // starts the block clock
    try await settle()
    model.openInScope(osc)
    for _ in 0..<5 {
      // Three blocks fall due at once: one request carries all three.
      now += 3 * block + 1e-6
      model.tick(now: now)
      try await settle()
    }
    let stream = try XCTUnwrap(app.streams.stream(StreamID("patch.\(osc).out")))
    let s = stream.ring.snapshot()
    XCTAssertGreaterThanOrEqual(s.count, 12 * NodeCatalog.blockSize, "every block reaches the Scope")
    var worstGap = 0.0
    for k in 1..<s.times.count { worstGap = max(worstGap, s.times[k] - s.times[k - 1]) }
    XCTAssertLessThan(worstGap, 1.5 / NodeCatalog.audioRate, "no holes between blocks")

    // The last reply came after the last tick's refresh: one refresh takes its new spectrum.
    model.refreshPreviews(force: true)
    let buffer = try XCTUnwrap(model.waterfalls[sink])
    let rows = buffer.revision
    XCTAssertGreaterThan(rows, 0)
    // An edit, a knob turn or a paused step refreshes too, with no new spectrum: no new row.
    for _ in 0..<5 { model.refreshPreviews(force: true) }
    XCTAssertEqual(buffer.revision, rows, "a refresh without a new spectrum adds no waterfall row")
    model.setVisible(false)
  }

  /// A node added from the palette or "Modulate from…" lands clear of every card (it used to
  /// test only top edges 120 pt apart, so an Oscillator landed across three cards), a column
  /// gutter from its neighbours (16 pt let its outputs face the Wigner's input as if cabled),
  /// and off every cable (it covered the Spin FID's I/Q cable).
  @MainActor
  func testNewCardsLandClearOfOtherCards() throws {
    let name = "Spectra.graphtests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    let app = AppModel(launch: LaunchOptions(arguments: ["Spectra", "-ui-testing"]), defaults: UserDefaults(suiteName: name)!)
    let model = app.patch
    model.load(preset: PatchPreset.earthNMR)
    model.fit(in: CGSize(width: 402, height: 560))
    for kind in [NodeKind.oscillator, .knob, .demodulator, .scope] {
      // The cables before this card arrives: it must not cover any of them.
      var points: [SIMD2<Double>] = []
      for c in model.graph.cables {
        let a = try XCTUnwrap(model.graph.node(c.from.node))
        let b = try XCTUnwrap(model.graph.node(c.to.node))
        let oa = try XCTUnwrap(PatchGeometry.portOffset(kind: a.kind, port: c.from.port, isInput: false))
        let ob = try XCTUnwrap(PatchGeometry.portOffset(kind: b.kind, port: c.to.port, isInput: true))
        points += PatchGeometry.cablePoints(from: SIMD2(a.x + oa.x, a.y + oa.y), to: SIMD2(b.x + ob.x, b.y + ob.y), count: 40)
      }
      let id = model.addNode(kind, at: model.freeSpot(kind: kind))
      let n = try XCTUnwrap(model.graph.node(id))
      let w = PatchGeometry.cardWidth
      let h = PatchGeometry.height(of: n.kind)
      for m in model.graph.nodes where m.id != id {
        let gutter = PatchGeometry.columnPitch - w
        let crowds =
          n.x < m.x + w + gutter - 1 && m.x < n.x + w + gutter - 1
          && n.y < m.y + PatchGeometry.height(of: m.kind) && m.y < n.y + h
        XCTAssertFalse(crowds, "new \(kind.rawValue) \(id) lands on or beside \(m.title)")
      }
      let gutter = PatchGeometry.columnPitch - w
      XCTAssertFalse(
        points.contains { $0.x > n.x - gutter && $0.x < n.x + w + gutter && $0.y > n.y && $0.y < n.y + h },
        "new \(kind.rawValue) covers a cable or has one running past its ports")
    }
  }

  /// A strip marker computed from a live or simulated sensor says so.
  @MainActor
  func testMarkerProvenanceNamesTheSensor() {
    XCTAssertEqual(PatchModel.markerProvenance([.model, .live]), .live)
    XCTAssertEqual(PatchModel.markerProvenance([.model, .sim, .analogy]), .sim)
    XCTAssertEqual(PatchModel.markerProvenance([.model]), .model)
    XCTAssertEqual(PatchModel.markerProvenance([]), .model)
  }

  // MARK: Review 2: stream sensors, the rotor's badge, the time chip, carrier markers

  /// A stream id names its sensor exactly (API-live §2): Spin's simulated top `gyro.tip.*` is
  /// not the gyroscope sensor (it held the motion sensor and showed its icon and state), and
  /// `gravity.*` and `device.*` belong to motion and charging. The rotor is ANALOGY (rule R2).
  @MainActor
  func testStreamIDsMapToTheirSensorsAndTheRotorIsAnalogy() {
    XCTAssertEqual(PatchModel.sensor(forStream: "gyro.x"), .motion)
    XCTAssertEqual(PatchModel.sensor(forStream: "gravity.z"), .motion)
    XCTAssertEqual(PatchModel.sensor(forStream: "attitude.yaw"), .motion)
    XCTAssertEqual(PatchModel.sensor(forStream: "mag.raw.norm"), .magnetometer)
    XCTAssertEqual(PatchModel.sensor(forStream: "ble.1234.rssi"), .bluetooth)
    XCTAssertEqual(PatchModel.sensor(forStream: "device.thermal"), .charging)
    XCTAssertNil(PatchModel.sensor(forStream: "gyro.tip.i"))
    XCTAssertNil(PatchModel.sensor(forStream: "gyro.tip.q"))
    XCTAssertNil(PatchModel.sensor(forStream: "spin.fid"))
    XCTAssertNil(PatchModel.sensor(forStream: "radio.i"))
    let tip = SignalStream(
      id: "gyro.tip.i", label: "Gyroscope tip I", unit: "eₓ", nominalRate: 960, provenance: .model, group: StreamGroup.spin)
    let fid = SignalStream(
      id: "spin.fid", label: "Spin FID I", unit: "M₀", nominalRate: 4000, provenance: .model, isEM: true, lambda: 140.8e3,
      group: StreamGroup.spin)
    let mic = SignalStream(id: "mic.left", label: "Mic", unit: "FS", nominalRate: 48_000, provenance: .sim, group: StreamGroup.audio)
    XCTAssertTrue(PatchModel.isAnalogy(tip), "the rotor is not electromagnetic")
    XCTAssertFalse(PatchModel.isAnalogy(fid), "a spin's FID is an EM signal")
    XCTAssertTrue(PatchModel.isAnalogy(mic))
  }

  /// Rule R3: a Gyroscope tip's Time dial off 1 makes the transport declare the slowing.
  @MainActor
  func testTimeMappingFollowsTheGyroscopeTimeDial() throws {
    let name = "Spectra.graphtests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    let app = AppModel(launch: LaunchOptions(arguments: ["Spectra", "-ui-testing"]), defaults: UserDefaults(suiteName: name)!)
    let model = app.patch
    model.load(preset: PatchPreset.gyroArray)
    XCTAssertEqual(model.timeMapping, .realTime)
    let gyro = try XCTUnwrap(model.graph.nodes.first { $0.kind == .gyroscope })
    model.setNumber(gyro.id, "time", 0.25)
    XCTAssertEqual(model.timeMapping, .slowed(factor: 4))
    model.setNumber(gyro.id, "time", 1)
    XCTAssertEqual(model.timeMapping, .realTime)
  }

  /// A Modulator whose carrier comes from a cable puts that carrier on the strip, not its idle
  /// Carrier dial (462.6 MHz).
  @MainActor
  func testModulatorMarkerFollowsItsCarrierInput() async throws {
    let name = "Spectra.graphtests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    let app = AppModel(launch: LaunchOptions(arguments: ["Spectra", "-ui-testing"]), defaults: UserDefaults(suiteName: name)!)
    let model = app.patch
    model.clear()
    let source = model.addNode(.spectraSource, at: .zero)
    model.setString(source, "follow", "own")
    model.setNumber(source, "lambda", 0.1229)  // 2.44 GHz
    let bits = model.addNode(.bits, at: CGPoint(x: 0, y: 320))
    let mod = model.addNode(.modulator, at: CGPoint(x: 212, y: 0))
    model.setString(mod, "mode", "qpsk")
    XCTAssertNil(model.connect(from: PortRef(bits, "bits"), to: PortRef(mod, "message")))
    let dial = try XCTUnwrap(model.markers.first { $0.id == "patch.\(mod)" })
    XCTAssertEqual(SpectrumMarker.frequency(forLambda: dial.lambda) / 462.6e6, 1, accuracy: 1e-6)
    XCTAssertNil(model.connect(from: PortRef(source, "wave"), to: PortRef(mod, "carrier")))
    XCTAssertNil(model.markers.first { $0.id == "patch.\(mod)" }, "no marker at the stale dial before the carrier flows")
    for _ in 0..<4 {
      model.stepOnce()
      for _ in 0..<20 { try await Task.sleep(for: .milliseconds(15)) }
    }
    model.refreshPreviews(force: true)
    let cabled = try XCTUnwrap(model.markers.first { $0.id == "patch.\(mod)" })
    XCTAssertEqual(SpectrumMarker.frequency(forLambda: cabled.lambda) / 2.44e9, 1, accuracy: 1e-3)
  }
  #endif
}
