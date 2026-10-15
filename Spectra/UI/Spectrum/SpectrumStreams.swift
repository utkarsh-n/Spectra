import Foundation

/// The Spectrum tab's signals on the scope bus (`AppModel.streams`), registered the first time
/// someone asks for them ("Open in Scope", "Add to Patch") and fed while the app is active:
///
/// - `spectrum.ex`, `spectrum.ey`: the summed field of the enabled sources at z = 0, in display
///   units (1 = the summed E₀), sampled at 240 Hz on κ-slowed screen time (MODEL).
/// - `spectrum.lab`: the Spectroscopy lab detector at the cursor, normalized to the sample's
///   maximum, 30 Hz (MODEL; TABLE for liquid water). Sweeping draws the spectrum over time,
///   like a chart recorder.
///
/// Values come from `FieldView.fieldAt` and `SampleKey.value` (Core).
@MainActor
final class SpectrumStreams {
  static let fieldRate = 240.0
  static let labRate = 30.0
  static let ex: StreamID = "spectrum.ex"
  static let ey: StreamID = "spectrum.ey"
  static let lab: StreamID = "spectrum.lab"
  static let group = "Spectrum"

  private weak var model: SpectrumModel?
  private weak var app: AppModel?
  private var exStream: SignalStream?
  private var eyStream: SignalStream?
  private var labStream: SignalStream?
  /// The sample the lab stream was registered for (its label and provenance name it).
  private var labSample: SampleKey?
  private var task: Task<Void, Never>?
  private var display: FieldView.DisplaySources?
  /// Wall time of the next field and lab samples.
  private var nextField: Double?
  private var nextLab: Double?

  init() {}

  func attach(model: SpectrumModel, app: AppModel) {
    self.model = model
    self.app = app
  }

  /// True once the lab detector is on the scope bus (registered by Open in Scope / Add to
  /// Patch and still in the registry).
  var labOnBus: Bool {
    guard let labStream, let app else { return false }
    return app.streams.stream(labStream.id) === labStream
  }

  /// Registers `spectrum.ex` / `spectrum.ey` (if needed) and returns their ids. A stream's λ
  /// (its colour on the scope) is fixed when it is made, so asking again after a retune
  /// registers fresh streams at the new λ.
  @discardableResult
  func ensureField() -> [StreamID] {
    guard let app, let model else { return [] }
    let lambda = model.state.referenceSource.lambda
    if Self.stale(exStream, lambda: lambda, provenance: .model, in: app) {
      let s = SignalStream(
        id: Self.ex, label: "Spectrum Ex at z = 0 (κ-slowed)", unit: "E (norm.)", nominalRate: Self.fieldRate,
        provenance: .model, isEM: true, lambda: lambda, group: Self.group)
      exStream = s
      app.streams.register(s)
    }
    if Self.stale(eyStream, lambda: lambda, provenance: .model, in: app) {
      let s = SignalStream(
        id: Self.ey, label: "Spectrum Ey at z = 0 (κ-slowed)", unit: "E (norm.)", nominalRate: Self.fieldRate,
        provenance: .model, isEM: true, lambda: lambda, group: Self.group)
      eyStream = s
      app.streams.register(s)
    }
    start()
    return [Self.ex, Self.ey]
  }

  /// Registers `spectrum.lab` (if needed, or again when the sample, its provenance or the
  /// probed λ changed since) and returns its id.
  @discardableResult
  func ensureLab() -> [StreamID] {
    guard let app, let model else { return [] }
    let provenance = Provenance(rawValue: model.state.lab.sample.source.rawValue) ?? .model
    let lambda = model.active.lambda
    if labSample != model.state.lab.sample || Self.stale(labStream, lambda: lambda, provenance: provenance, in: app) {
      let s = SignalStream(
        id: Self.lab, label: "Spectroscopy lab detector (\(model.state.lab.sample.name))", unit: "rel.",
        nominalRate: Self.labRate, provenance: provenance, isEM: true, lambda: lambda, group: Self.group)
      labStream = s
      labSample = model.state.lab.sample
      app.streams.register(s)
    }
    start()
    return [Self.lab]
  }

  /// True when `stream` is missing from the registry, or was made for another provenance or
  /// for a λ more than 1 % away.
  private static func stale(_ stream: SignalStream?, lambda: Double, provenance: Provenance, in app: AppModel) -> Bool {
    guard let stream, app.streams.stream(stream.id) === stream else { return true }
    guard stream.provenance == provenance, let old = stream.lambda, old > 0, lambda > 0 else { return true }
    return abs(log10(lambda / old)) > 0.004
  }

  private func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(25))
        self?.pump()
      }
    }
  }

  /// Writes every sample due since the last pump (at most 0.5 s of backlog).
  private func pump() {
    guard let model, let app else { return }
    let now = SignalClock.now()
    guard app.isActive, app.selectedTab == .spectrum || app.selectedTab == .live || app.selectedTab == .patch else {
      // Nobody can be looking: drop the backlog instead of computing it.
      nextField = nil
      nextLab = nil
      return
    }
    if let ex = exStream, let ey = eyStream {
      let state = model.state
      if display?.isCurrent(sources: state.sources, medium: state.medium) != true {
        display = FieldView.displaySources(state)
      }
      guard let ds = display else { return }
      var t = max(nextField ?? now, now - 0.5)
      var xs: [Float] = []
      var ys: [Float] = []
      let start = t
      // Screen time follows the app clock (κ-slowed, held while paused) so the scope shows
      // what the Wave scope shows.
      let clock = app.clock
      let moving = clock.isAnimating ? 1.0 : 0.0
      while t <= now {
        let f = FieldView.fieldAt(ds, z: 0, t: clock.time - (now - t) * moving, speed: state.speed)
        xs.append(Float(f.ex))
        ys.append(Float(f.ey))
        t += 1 / Self.fieldRate
      }
      if !xs.isEmpty {
        ex.ring.append(contentsOf: xs, start: start, interval: 1 / Self.fieldRate)
        ey.ring.append(contentsOf: ys, start: start, interval: 1 / Self.fieldRate)
      }
      nextField = t
    }
    if let lab = labStream {
      // The Earth-field mode's detector is the magnetometer (`mag.norm`, LIVE/SIM): its
      // reading must not go out on this MODEL/TABLE stream, which holds until a sample shows.
      guard !model.extras.labEarth else {
        nextLab = nil
        return
      }
      // Another sample since it was registered: register it again so its label and badge
      // (TABLE for liquid water, else MODEL) name what it now carries. The scope finds
      // streams by id, so an open channel follows.
      var stream = lab
      if labSample != model.state.lab.sample {
        ensureLab()
        guard let fresh = labStream else { return }
        stream = fresh
      }
      var t = max(nextLab ?? now, now - 0.5)
      let value = Float(model.labReading())
      while t <= now {
        stream.append(value, at: t)
        t += 1 / Self.labRate
      }
      nextLab = t
    }
  }
}
