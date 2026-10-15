import Foundation

/// The simulated streams the Spin FID and Radio I/Q probes need when no other slice publishes
/// them (SPEC-features §3b, probe 10).
nonisolated enum ScopeProbeKind: String, Codable, Sendable, CaseIterable {
  case spinFID, radioIQ
}

/// Publishes MODEL streams for the Spin FID and Radio I/Q probes while the scope shows them,
/// unless the Spin or Radio slice already publishes streams with the same ids (theirs win; a
/// registered stream is never replaced).
///
/// - `spin.fid`: a water-proton free-induction decay at its **true** Larmor pitch in the live
///   field |B| (≈ 2.1 kHz at 50 µT), sampled at 8 kHz and re-pulsed every 3 s, rendered by the
///   Spin engine's `SpinFIDSource`. REAL TIME.
/// - `radio.i`, `radio.q`: EDGE 8-PSK baseband through a 30 dB channel (`RF.BasebandLink`),
///   played out at 200 samples per displayed second (25 symbols/s), i.e. κ-slowed by
///   f_s / 200 ≈ 10⁴.
///
/// Samples are generated on the main actor at frame rate from the scope's tick, stamped on
/// `SignalClock` like any sensor.
@MainActor
final class ScopeProbeStreams {
  static let fidID: StreamID = "spin.fid"
  static let iID: StreamID = "radio.i"
  static let qID: StreamID = "radio.q"
  /// Sample rate of the simulated FID (Hz): above twice the ~2.1 kHz Larmor line.
  static let fidRate = 8000.0
  /// Displayed I/Q samples per second.
  static let iqDisplayRate = 200.0
  /// Re-pulse period of the FID (s).
  static let fidRepeat = 3.0

  private(set) var published: [ScopeProbeKind: [SignalStream]] = [:]

  private var fid: SpinFIDSource?
  private var fidNext = 0.0
  private var link: RF.BasebandLink?
  private var iqI: [Float] = []
  private var iqQ: [Float] = []
  private var iqIndex = 0
  private var iqNext = 0.0
  private var lastFieldTime: Double?

  init() {}

  /// The time mapping of the I/Q streams this object publishes (κ-slowed by f_s / 200).
  var radioTimeMapping: TimeMapping {
    .slowed(factor: (link?.sampleRate ?? Self.edgeSampleRate) / Self.iqDisplayRate)
  }

  /// EDGE's simulated sample rate: 270.833 ksym/s × 8 samples per symbol.
  static var edgeSampleRate: Double { RF.Numerology.GSM.symbolRate * 8 }

  /// Whether `id` is a stream this object publishes right now.
  func owns(_ id: StreamID) -> Bool {
    published.values.contains { list in list.contains { $0.id == id } }
  }

  /// Starts exactly the probe streams in `kinds` (those already published by another slice
  /// are left alone) and stops the rest.
  func ensure(_ kinds: Set<ScopeProbeKind>, registry: StreamRegistry) {
    for kind in ScopeProbeKind.allCases where !kinds.contains(kind) { stop(kind, registry: registry) }
    for kind in kinds where published[kind] == nil { start(kind, registry: registry) }
  }

  func stopAll(registry: StreamRegistry) {
    for kind in ScopeProbeKind.allCases { stop(kind, registry: registry) }
  }

  private func start(_ kind: ScopeProbeKind, registry: StreamRegistry) {
    let now = SignalClock.now()
    switch kind {
    case .spinFID:
      guard registry.stream(Self.fidID) == nil else { return }
      let stream = SignalStream(
        id: Self.fidID, label: "Proton FID (true pitch)", unit: "V (norm.)", nominalRate: Self.fidRate,
        provenance: .model, isEM: true, lambda: SpinSpecies.protonWater.larmorWavelength(field: EarthField.typicalField),
        group: StreamGroup.spin, capacity: Int(Self.fidRate * 4))
      var source = SpinFIDSource(
        species: .protonWater, field: EarthField.typicalField, sampleRate: Self.fidRate, t2Star: 0.6, level: 1,
        repeatInterval: Self.fidRepeat)
      source.pulse()
      fid = source
      fidNext = now
      lastFieldTime = nil
      registry.register(stream)
      published[.spinFID] = [stream]
    case .radioIQ:
      guard registry.stream(Self.iID) == nil, registry.stream(Self.qID) == nil,
        let system = RF.SystemsCatalog.system(id: "edge")
      else { return }
      var config = RF.BasebandLinkConfig(system: system)
      config.snrDB = 30
      config.targetSamples = 4096
      config.seed = 7
      link = RF.BasebandLink(config)
      iqI = []
      iqQ = []
      iqIndex = 0
      iqNext = now
      let lambda = SpectrumMarker.lambda(forFrequency: system.carrier)
      let i = SignalStream(
        id: Self.iID, label: "Radio I (EDGE 8-PSK)", unit: "V (norm.)", nominalRate: Self.iqDisplayRate,
        provenance: .model, isEM: true, lambda: lambda, group: StreamGroup.radio)
      let q = SignalStream(
        id: Self.qID, label: "Radio Q (EDGE 8-PSK)", unit: "V (norm.)", nominalRate: Self.iqDisplayRate,
        provenance: .model, isEM: true, lambda: lambda, group: StreamGroup.radio)
      registry.register([i, q])
      published[.radioIQ] = [i, q]
    }
  }

  private func stop(_ kind: ScopeProbeKind, registry: StreamRegistry) {
    guard let list = published.removeValue(forKey: kind) else { return }
    for s in list { registry.unregister(s) }
    switch kind {
    case .spinFID: fid = nil
    case .radioIQ: link = nil
    }
  }

  /// Generates samples up to `now`. `fieldTesla` is the live |B| (nil keeps the last field).
  /// After a pause the streams jump forward instead of catching up.
  ///
  /// With `registry`: when the Spin or Radio slice registers its own stream under the same id
  /// (`register` replaces by id), the fallback stops writing its orphaned instance; when that
  /// slice later unregisters, the fallback registers its instance again so the probe's channel
  /// keeps a stream (spin-ui-requests §4, integration).
  func pump(now: Double, fieldTesla: Double?, registry: StreamRegistry? = nil) {
    if let registry {
      for list in published.values {
        for s in list where registry.stream(s.id) == nil { registry.register(s) }
      }
    }
    if var source = fid, let stream = published[.spinFID]?.first,
      registry.map({ $0.stream(Self.fidID) === stream }) ?? true
    {
      if let b = fieldTesla, b.isFinite, b > 0 {
        let dt = lastFieldTime.map { max(0, now - $0) } ?? 0
        source.updateField(b, dt: dt)
        lastFieldTime = now
      }
      if now - fidNext > 0.5 { fidNext = now - 0.05 }
      let count = Int(((now - fidNext) * Self.fidRate).rounded(.down))
      if count > 0 {
        let block = source.renderAudio(count)
        stream.ring.append(contentsOf: block, start: fidNext, interval: 1 / Self.fidRate)
        fidNext += Double(count) / Self.fidRate
      }
      fid = source
    }
    if link != nil, let list = published[.radioIQ], list.count == 2,
      registry.map({ $0.stream(Self.iID) === list[0] }) ?? true
    {
      if now - iqNext > 1 { iqNext = now - 0.05 }
      var values: [(Float, Float)] = []
      var times: [Double] = []
      while iqNext <= now {
        if iqIndex >= iqI.count { refill() }
        guard iqIndex < iqI.count else { break }
        values.append((iqI[iqIndex], iqQ[iqIndex]))
        times.append(iqNext)
        iqIndex += 1
        iqNext += 1 / Self.iqDisplayRate
      }
      if !times.isEmpty {
        list[0].ring.append(contentsOf: values.map(\.0), times: times)
        list[1].ring.append(contentsOf: values.map(\.1), times: times)
      }
    }
  }

  private func refill() {
    guard var l = link else { return }
    let frame = l.next()
    link = l
    iqI = frame.rx.i
    iqQ = frame.rx.q
    iqIndex = 0
  }
}
