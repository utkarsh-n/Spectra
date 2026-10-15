import Foundation
import Observation
import simd
import SwiftUI

/// What `Spectra.patch.v1` stores: the graph, the canvas view, and which permission-gated
/// sensors you have started from a Patch node (so only that first start is a tap).
nonisolated struct PatchDocument: Codable, Sendable, Equatable {
  static let storageKey = "Spectra.patch.v1"

  var graph: PatchGraph
  /// Canvas pan (points) and zoom.
  var offsetX = 0.0
  var offsetY = 0.0
  var zoom = 0.8
  var startedSensors: Set<SensorID> = []
  /// The preset the graph came from, if it is unedited since.
  var presetID: String?
  /// Cards land on an 8-point grid.
  var snapToGrid = true

  init(graph: PatchGraph, presetID: String? = nil) {
    self.graph = graph
    self.presetID = presetID
  }

  private enum CodingKeys: String, CodingKey { case graph, offsetX, offsetY, zoom, startedSensors, presetID, snapToGrid }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    graph = ((try? c.decode(PatchGraph.self, forKey: .graph)) ?? PatchGraph()).repaired()
    offsetX = (try? c.decode(Double.self, forKey: .offsetX)) ?? 0
    offsetY = (try? c.decode(Double.self, forKey: .offsetY)) ?? 0
    zoom = min(max((try? c.decode(Double.self, forKey: .zoom)) ?? 0.8, PatchModel.zoomRange.lowerBound), PatchModel.zoomRange.upperBound)
    startedSensors = (try? c.decode(Set<SensorID>.self, forKey: .startedSensors)) ?? []
    presetID = try? c.decode(String.self, forKey: .presetID)
    snapToGrid = (try? c.decode(Bool.self, forKey: .snapToGrid)) ?? true
  }
}

/// How a cable or a node's preview is tinted (rule R2: hue only for EM frequency).
enum PatchTint: Equatable {
  /// Band colour of an EM wave or a carrier (vacuum λ, m).
  case band(Double)
  /// Sound, motion, samples: phosphor (ANALOGY).
  case phosphor
  /// Control values, events, bits: amber.
  case amber
  /// Nothing has flowed yet.
  case idle
}

/// A node card's live preview, refreshed about 15 times a second while the tab is visible.
struct NodePreview {
  enum Plot {
    case none
    /// Newest value at the right.
    case trace([Double], steps: Bool)
    /// dB values across the band.
    case spectrum([Double], floor: Double)
    case points([SIMD2<Float>], ideal: [SIMD2<Float>], range: Float)
    /// Signed −1…1 values, `side` × `side`, rows = time (top = oldest).
    case image([Float], side: Int)
    case swatch(lambda: Double)
    case text(String)
    case level(Double)
  }

  var plot: Plot = .none
  /// The headline number, formatted.
  var value: String?
  var tint: PatchTint = .idle
  /// Badges of what the preview shows.
  var provenance: [Provenance] = []
}

/// The Patch tab's model (SPEC.md §3.6): the graph document, the evaluator, and the bindings
/// to live sensors, the synth, haptics, the scope bus and `AppModel.sendToSpectrum`.
/// Evaluation runs only while the Patch tab is visible and the clock plays.
@Observable @MainActor
final class PatchModel: TabModel {
  nonisolated static let zoomRange = 0.35...1.6
  static let previewInterval = 1.0 / 15

  // MARK: Observed state

  /// The patch. Edit it through the methods below (they keep it acyclic, typed and saved).
  private(set) var graph: PatchGraph
  var offset = CGSize.zero
  var zoom = 0.8
  /// The node whose card is highlighted.
  var selection: String?
  /// The node the inspector sheet shows.
  var inspecting: String?
  /// A node the canvas should scroll to (set when one is added from elsewhere).
  var focusRequest: String?
  /// Cards land on an 8-point grid.
  var snapToGrid = true
  /// Bumped when previews refresh; cards read it to redraw.
  private(set) var revision = 0
  private(set) var isRunning = false
  /// Average CPU per step, ms.
  private(set) var stepMilliseconds = 0.0
  /// Steps per second over the last second.
  private(set) var stepRate = 0.0
  private(set) var presetID: String?
  private(set) var canRestore = false
  /// Wavelengths of markers that come from running values (Larmor, rulers, blackbody peaks),
  /// observed so the Spectrum strip follows them.
  private(set) var liveMarkers: [String: Double] = [:]

  // MARK: Not observed

  /// What the views read of the evaluator (values, statuses, drives), as of the last reply
  /// from the runner, which steps the graph off the main actor.
  @ObservationIgnored private(set) var snapshot: GraphSnapshot
  @ObservationIgnored private let runner: GraphRunner
  /// One request at a time keeps loads and steps in order.
  @ObservationIgnored private var inFlight = false
  @ObservationIgnored private var pendingLoad: PatchGraph?
  @ObservationIgnored private var pendingReset = false
  /// Steps asked for while a request was in flight (Step one block).
  @ObservationIgnored private var queuedWorlds: [GraphInputs] = []
  /// Bumped when the graph stops: replies to older requests update values but play nothing.
  @ObservationIgnored private var runGeneration = 0
  /// The nodes a step runs (stream nodes outside it are not read).
  @ObservationIgnored private var activeNodes: Set<String> = []
  @ObservationIgnored private(set) var previews: [String: NodePreview] = [:]
  @ObservationIgnored private(set) var statuses: [String: NodeStatus] = [:]
  /// Waterfalls of Spectrum sink nodes.
  @ObservationIgnored private(set) var waterfalls: [String: WaterfallBuffer] = [:]
  /// The spectrum each waterfall last drew: a row goes in only for a new spectrum, not for
  /// every refresh (an edit or a knob turn refreshes too).
  @ObservationIgnored private var waterfallFrames: [String: SpectrumFrame] = [:]
  /// True while the view is where the last automatic fit put it: a canvas size change (the
  /// first layout passes) fits again, until you pan or zoom.
  @ObservationIgnored private(set) var autoFitted = false
  @ObservationIgnored private var histories: [String: [Double]] = [:]
  /// Gyroscope tip trails (the precession circle), newest last.
  @ObservationIgnored private var trails: [String: [SIMD2<Float>]] = [:]
  /// Start time of the block each trace last drew (held blocks are not drawn twice).
  @ObservationIgnored private var recordedBlock: [String: Double] = [:]
  @ObservationIgnored private var cursors: [String: StreamCursor] = [:]
  @ObservationIgnored private var scheduler = BlockScheduler()
  @ObservationIgnored private var lastTick: Double?
  @ObservationIgnored private var lastPreview = 0.0
  @ObservationIgnored private var rateWindow: (start: Double, steps: Int) = (0, 0)
  /// Streams the Scope sinks and taps publish. Observed (it changes only when one registers or
  /// goes): the Scope node's inspector shows its streams as soon as they exist.
  private var scopeStreams: [String: SignalStream] = [:]
  @ObservationIgnored private var scopeLast: [String: Double] = [:]
  @ObservationIgnored private(set) var rulerValues: [String: (lambda: Double, label: String, provenance: [Provenance])] = [:]
  @ObservationIgnored private var lastTune = 0.0
  @ObservationIgnored private var humming = false
  @ObservationIgnored private var acquired: Set<SensorID> = []
  @ObservationIgnored private var startedSensors: Set<SensorID> = []
  @ObservationIgnored private var previous: PatchGraph?
  @ObservationIgnored private var externalBase: [String: Double] = [:]
  @ObservationIgnored private var registeredKnobs: [String: String] = [:]
  /// Other tabs' knobs registered by "Modulate from…" in a `KnobGrid` (integration): how to
  /// read and set the knob's value, and its scale, so a Knob target can drive any of them.
  @ObservationIgnored private var externalKnobs: [String: ExternalKnob] = [:]
  @ObservationIgnored private var externalSetTime: [String: Double] = [:]

  struct ExternalKnob {
    let scale: KnobScale
    let get: () -> Double
    let set: (Double) -> Void
  }
  @ObservationIgnored private var store: JSONStore<PatchDocument>?
  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private var visible = false
  /// Node outputs published on the scope bus because "Open in Scope" asked for them.
  @ObservationIgnored private var taps: [PortRef] = []
  /// Set by "Open in Scope": the graph keeps running while the Live tab (where the Scope
  /// draws its streams) is on screen, the "node-dependent view" of SPEC-features §5.
  @ObservationIgnored private var feedsScope = false
  @ObservationIgnored private var scopeDriver: Task<Void, Never>?
  @ObservationIgnored private var lastClockTime: Double?
  /// True once the canvas has reported its size (fits wait for it).
  @ObservationIgnored private var viewportKnown = false
  @ObservationIgnored var needsFit = true
  /// A sheet the canvas opens when it first appears ("palette", "presets"), from `-open`.
  @ObservationIgnored var launchSheet: String?
  /// A section the inspector opens large and scrolled to ("live", "dials", "cables"), from `-open`.
  @ObservationIgnored var inspectorFocus: String?

  init() {
    graph = PatchPreset.starter.graph
    presetID = PatchPreset.starter.id
    let evaluator = GraphEvaluator(graph: PatchPreset.starter.graph)
    snapshot = evaluator.snapshot
    activeNodes = evaluator.active
    runner = GraphRunner(graph: PatchPreset.starter.graph)
  }

  func attach(to app: AppModel) {
    self.app = app
    let store = JSONStore<PatchDocument>(key: PatchDocument.storageKey)
    self.store = store
    if !app.launch.uiTesting, let doc = store.load() {
      apply(doc)
    }
    // -open patch/<preset>[/<nodeID>|palette|presets]: screenshots and UI tests.
    if app.launch.openTab == .patch, let path = app.launch.openPath {
      let parts = path.split(separator: "/").map(String.init)
      if let first = parts.first, let preset = PatchPreset.named(first) {
        install(preset.graph, preset: preset.id, remember: false)
      }
      for extra in parts where parts.count > 1 || PatchPreset.named(extra) == nil {
        switch extra {
        case "palette": launchSheet = "palette"
        case "presets": launchSheet = "presets"
        case "dials", "live", "cables": inspectorFocus = extra
        default: if graph.node(extra) != nil { inspecting = extra }
        }
      }
    }
  }

  private func apply(_ doc: PatchDocument) {
    graph = doc.graph
    offset = CGSize(width: doc.offsetX, height: doc.offsetY)
    zoom = doc.zoom
    startedSensors = doc.startedSensors
    presetID = doc.presetID
    snapToGrid = doc.snapToGrid
    queueLoad(graph)
    // The saved pan and zoom are where you left the canvas: keep them instead of fitting.
    if doc.offsetX != 0 || doc.offsetY != 0 { needsFit = false }
  }

  /// Writes the document (debounced).
  func save() {
    guard let store, app?.launch.uiTesting != true else { return }
    var doc = PatchDocument(graph: graph, presetID: presetID)
    doc.offsetX = offset.width
    doc.offsetY = offset.height
    doc.zoom = zoom
    doc.startedSensors = startedSensors
    doc.snapToGrid = snapToGrid
    store.schedule(doc)
  }

  // MARK: - Markers (the loop)

  var markers: [SpectrumMarker] {
    var out: [SpectrumMarker] = []
    for n in graph.nodes {
      let id = "patch.\(n.id)"
      switch n.kind {
      case .spectraSource where n.string("follow") != "A":
        out.append(SpectrumMarker(id: id, label: "Patch: \(n.title)", lambda: n.number("lambda"), provenance: .model, tab: .patch))
      case .modulator:
        // A cabled carrier input sets the carrier: its running value, not the idle dial.
        if let lambda = liveMarkers[n.id] {
          out.append(SpectrumMarker(id: id, label: "Patch: \(n.title) carrier", lambda: lambda, provenance: .model, tab: .patch))
        } else if graph.cable(into: PortRef(n.id, "carrier")) == nil {
          out.append(
            SpectrumMarker(id: id, label: "Patch: \(n.title) carrier", frequency: n.number("carrier"), provenance: .model, tab: .patch))
        }
      case .antenna where graph.cable(into: PortRef(n.id, "signal")) == nil:
        out.append(SpectrumMarker(id: id, label: "Patch: \(n.title)", frequency: n.number("frequency"), provenance: .model, tab: .patch))
      case .spinFID:
        if let lambda = liveMarkers[n.id] {
          let badges = snapshot.value(at: PortRef(n.id, "larmor"))?.provenance ?? [.model]
          out.append(
            SpectrumMarker(id: id, label: "Patch: Larmor", lambda: lambda, provenance: Self.markerProvenance(badges), tab: .patch))
        }
      case .blackbody:
        if let lambda = liveMarkers[n.id] {
          let badges = snapshot.value(at: PortRef(n.id, "peak"))?.provenance ?? [.model]
          out.append(
            SpectrumMarker(
              id: id, label: "Patch: blackbody peak", lambda: lambda, provenance: Self.markerProvenance(badges), tab: .patch))
        }
      case .oscillator:
        let f = n.number("f")
        if f >= 1 {
          out.append(SpectrumMarker(id: id, label: "Patch: \(n.title)", frequency: f, provenance: .analogy, tab: .patch, isEM: false))
        }
      case .ruler:
        if liveMarkers[n.id] != nil, let r = rulerValues[n.id] {
          out.append(
            SpectrumMarker(
              id: id, label: "Patch ruler: \(r.label)", lambda: r.lambda, provenance: Self.markerProvenance(r.provenance),
              tab: .patch))
        }
      default: break
      }
    }
    return out
  }

  /// Rule R3 for the transport chip: the patch runs in real time unless a Gyroscope tip's Time
  /// dial slows (or speeds) its top; the slowest one is declared.
  var timeMapping: TimeMapping {
    let scales = graph.nodes.filter { $0.kind == .gyroscope }.map { $0.number("time") }
      .filter { $0.isFinite && $0 > 0 && abs($0 - 1) > 1e-3 }
    guard let d = scales.min() else { return .realTime }
    return .slowed(factor: 1 / d)
  }

  /// A strip marker holds one badge: the one that says where the value comes from (a value
  /// computed from a live or simulated sensor is LIVE or SIM, not plain MODEL).
  static func markerProvenance(_ badges: [Provenance]) -> Provenance {
    if badges.contains(.live) { return .live }
    if badges.contains(.sim) { return .sim }
    return badges.first ?? .model
  }

  // MARK: - Editing

  /// Replaces the graph after an edit: re-evaluates order, saves, starts what it needs.
  private func commit(_ next: PatchGraph, keepPreset: Bool = false) {
    let removed = Set(graph.nodes.map(\.id)).subtracting(next.nodes.map(\.id))
    graph = next
    if !keepPreset { presetID = nil }
    queueLoad(next)
    for id in removed { forget(node: id) }
    if let s = selection, next.node(s) == nil { selection = nil }
    if let s = inspecting, next.node(s) == nil { inspecting = nil }
    syncSensors()
    refreshPreviews(force: true)
    save()
  }

  private func forget(node id: String) {
    previews[id] = nil
    taps.removeAll { $0.node == id }
    histories = histories.filter { !$0.key.hasPrefix(id + ".") && $0.key != id }
    cursors[id] = nil
    trails[id] = nil
    recordedBlock[id] = nil
    recordedBlock["trail.\(id)"] = nil
    waterfalls[id] = nil
    waterfallFrames[id] = nil
    rulerValues[id] = nil
    for (key, s) in scopeStreams where key.hasPrefix(id + ".") {
      app?.streams.unregister(s)
      scopeStreams[key] = nil
      scopeLast[key] = nil
    }
  }

  /// Adds a node at a canvas point (world coordinates of the card's top-left corner).
  @discardableResult
  func addNode(_ kind: NodeKind, at point: CGPoint, label: String? = nil, stream: String? = nil) -> String {
    var g = graph
    var node = g.add(kind, x: point.x.rounded(), y: point.y.rounded())
    node.label = label
    if let stream { node.strings["stream"] = stream }
    if let i = g.index(of: node.id) { g.nodes[i] = node }
    commit(g)
    selection = node.id
    app?.haptics.success()
    return node.id
  }

  /// Adds a palette item near `point`.
  @discardableResult
  func add(_ item: PaletteItem, at point: CGPoint) -> String {
    addNode(item.kind, at: point, label: item.stream == nil ? nil : item.title, stream: item.stream)
  }

  /// Moves a card (no save until `endMove`).
  func move(_ id: String, to point: CGPoint) {
    guard let i = graph.index(of: id) else { return }
    graph.nodes[i].x = point.x
    graph.nodes[i].y = point.y
  }

  func endMove() {
    queueLoad(graph)
    save()
  }

  /// Connects two ports. Returns the reason when it cannot (and plays the boundary haptic).
  @discardableResult
  func connect(from: PortRef, to: PortRef) -> GraphError? {
    var g = graph
    do {
      try g.connect(from: from, to: to)
    } catch {
      app?.haptics.boundary()
      return error
    }
    commit(g)
    app?.haptics.detent()
    return nil
  }

  func disconnect(input: PortRef) {
    var g = graph
    guard g.disconnect(input: input) != nil else { return }
    commit(g)
    app?.haptics.tick()
  }

  func remove(node id: String) {
    var g = graph
    g.remove(node: id)
    commit(g)
    app?.haptics.resetClick()
  }

  @discardableResult
  func duplicate(node id: String) -> String? {
    guard let n = graph.node(id) else { return nil }
    var g = graph
    var copy = g.add(n.kind, x: n.x + 24, y: n.y + 24)
    copy.label = n.label
    copy.numbers = n.numbers
    copy.strings = n.strings
    if let i = g.index(of: copy.id) { g.nodes[i] = copy }
    commit(g)
    selection = copy.id
    app?.haptics.success()
    return copy.id
  }

  func setNumber(_ id: String, _ param: String, _ value: Double) {
    guard let i = graph.index(of: id), value.isFinite else { return }
    var g = graph
    g.nodes[i].numbers[param] = g.nodes[i].spec.param(param)?.scale?.clamp(value) ?? value
    commit(g)
  }

  func setString(_ id: String, _ param: String, _ value: String) {
    guard let i = graph.index(of: id) else { return }
    var g = graph
    g.nodes[i].strings[param] = value
    // A Live stream node takes the stream's name as its title (a sensor that is not running
    // yet has no stream on the bus: its palette name stands in, never "Any stream…").
    if param == "stream" {
      if value == "ble.*" {
        g.nodes[i].label = "Bluetooth RSSI"
      } else if let s = app?.streams.stream(StreamID(value)) {
        g.nodes[i].label = s.label
      } else if let item = NodeCatalog.palette.first(where: { $0.stream == value }) {
        g.nodes[i].label = item.title
      } else if !value.isEmpty {
        g.nodes[i].label = value
      }
    }
    commit(g)
  }

  func rename(_ id: String, _ title: String) {
    guard let i = graph.index(of: id) else { return }
    var g = graph
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    g.nodes[i].label = t.isEmpty ? nil : t
    commit(g)
  }

  /// Restores every dial and choice of a node to its catalogue default. What the node reads
  /// or drives (a Live stream's stream, a Knob target's target) is a binding, not a dial: kept.
  func resetParameters(_ id: String) {
    guard let i = graph.index(of: id) else { return }
    var g = graph
    let kept = g.nodes[i].strings.filter { $0.key == "stream" || $0.key == "target" }
    g.nodes[i].numbers = [:]
    g.nodes[i].strings = kept
    commit(g, keepPreset: false)
  }

  /// Loads a preset (the previous patch can be restored once).
  func load(preset: PatchPreset) {
    install(preset.graph, preset: preset.id, remember: true)
    app?.haptics.success()
    app?.showToast("Loaded \(preset.title)", symbol: preset.symbol)
  }

  private func install(_ g: PatchGraph, preset: String?, remember: Bool) {
    if remember, graph != g, !graph.nodes.isEmpty {
      previous = graph
      canRestore = true
    }
    pendingReset = true
    commit(g, keepPreset: true)
    presetID = preset
    selection = nil
    inspecting = nil
    save()
    if viewportKnown { fit(in: lastViewport) } else { needsFit = true }
  }

  func restorePrevious() {
    guard let p = previous else { return }
    previous = graph
    pendingReset = true
    commit(p)
    // The restored patch may sit anywhere on the canvas: bring all of it into view.
    if viewportKnown { fit(in: lastViewport) }
    app?.haptics.success()
    app?.showToast("Previous patch restored", symbol: "arrow.uturn.backward")
  }

  func clear() {
    previous = graph
    canRestore = true
    commit(PatchGraph())
    app?.haptics.resetClick()
  }

  // MARK: - Viewport

  /// The canvas size the view last reported (for fitting).
  @ObservationIgnored var lastViewport = CGSize(width: 390, height: 560)

  /// Sets the zoom, keeping `anchor` (a view point; nil = the viewport's centre) fixed.
  func setZoom(_ z: Double, around anchor: CGPoint?) {
    let next = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    guard next.isFinite, next != zoom else { return }
    let a = anchor ?? CGPoint(x: lastViewport.width / 2, y: lastViewport.height / 2)
    let k = next / zoom
    offset = CGSize(width: a.x - (a.x - offset.width) * k, height: a.y - (a.y - offset.height) * k)
    zoom = next
    autoFitted = false
  }

  /// Pans the canvas (a drag on the background).
  func pan(to offset: CGSize) {
    self.offset = offset
    autoFitted = false
  }

  /// Scrolls so a node's card sits in the middle of the viewport.
  func center(on id: String) {
    guard let n = graph.node(id) else { return }
    autoFitted = false
    let cx = (n.x + PatchGeometry.cardWidth / 2) * zoom
    let cy = (n.y + PatchGeometry.height(of: n.kind) / 2) * zoom
    offset = CGSize(width: lastViewport.width / 2 - cx, height: lastViewport.height / 2 - cy)
  }

  /// Zooms and pans so every card fits in `size`.
  func fit(in size: CGSize) {
    // Before the canvas has a real size (first layout pass), wait for it.
    guard size.width > 50, size.height > 50 else {
      needsFit = true
      return
    }
    lastViewport = size
    viewportKnown = true
    needsFit = false
    autoFitted = true
    guard !graph.nodes.isEmpty else {
      offset = .zero
      zoom = 0.8
      return
    }
    let minX = graph.nodes.map(\.x).min() ?? 0
    let minY = graph.nodes.map(\.y).min() ?? 0
    let maxX = graph.nodes.map { $0.x + PatchGeometry.cardWidth }.max() ?? 1
    let maxY = graph.nodes.map { $0.y + PatchGeometry.height(of: $0.kind) }.max() ?? 1
    // Leave room for the toolbar above and the status chip below.
    let padX = 18.0
    let top = 62.0
    let bottom = 46.0
    let wz = (size.width - 2 * padX) / max(1, maxX - minX)
    let hz = (size.height - top - bottom) / max(1, maxY - minY)
    // Fit both ways down to 0.5 (cards stay legible, and nothing hides under the status
    // chip); a patch taller than that starts at its top at up to 0.6 and scrolls.
    let both = min(wz, hz)
    let z = both >= 0.5 ? both : min(wz, 0.6)
    zoom = min(max(z, Self.zoomRange.lowerBound), 1.1)
    offset = CGSize(
      width: (size.width - (maxX - minX) * zoom) / 2 - minX * zoom,
      height: top + max(0, (size.height - top - bottom - (maxY - minY) * zoom) / 2) - minY * zoom)
    save()
  }

  /// A free spot for a new card (of `kind`, for its height) near the middle of the visible
  /// canvas: the nearest place, on a 24-point lattice around the middle, where the card keeps
  /// clear of every other card (a column gutter, 40 pt, beside it, so no port of its faces a
  /// neighbour's at arm's length, and 16 pt above and below) and no cable runs under it or
  /// through the gutters where its ports sit.
  func freeSpot(near viewPoint: CGPoint? = nil, kind: NodeKind? = nil) -> CGPoint {
    let center = viewPoint ?? CGPoint(x: lastViewport.width / 2, y: lastViewport.height / 2)
    let w = PatchGeometry.cardWidth
    let h = kind.map(PatchGeometry.height(of:)) ?? 186
    let origin = CGPoint(x: (center.x - offset.width) / zoom - w / 2, y: (center.y - offset.height) / zoom - h / 2)
    let gapX = PatchGeometry.columnPitch - PatchGeometry.cardWidth
    let gapY = 16.0
    var cablePoints: [SIMD2<Double>] = []
    for c in graph.cables {
      guard let a = graph.node(c.from.node), let b = graph.node(c.to.node),
        let oa = PatchGeometry.portOffset(kind: a.kind, port: c.from.port, isInput: false),
        let ob = PatchGeometry.portOffset(kind: b.kind, port: c.to.port, isInput: true)
      else { continue }
      cablePoints += PatchGeometry.cablePoints(from: SIMD2(a.x + oa.x, a.y + oa.y), to: SIMD2(b.x + ob.x, b.y + ob.y), count: 40)
    }
    func free(_ p: CGPoint) -> Bool {
      let clearOfCards = !graph.nodes.contains { n in
        p.x < n.x + w + gapX && n.x < p.x + w + gapX && p.y < n.y + PatchGeometry.height(of: n.kind) + gapY
          && n.y < p.y + h + gapY
      }
      // No cable under the card, nor in the gutters beside it where its ports sit (a cable
      // passing its output dots would read as its cable).
      return clearOfCards
        && !cablePoints.contains { q in q.x > p.x - gapX && q.x < p.x + w + gapX && q.y > p.y - 8 && q.y < p.y + h + 8 }
    }
    // Rings of lattice points around the middle, nearest first; a full canvas falls back to
    // the middle itself.
    let step = 24.0
    for ring in 0...40 {
      var best: (p: CGPoint, d: Double)?
      for i in -ring...ring {
        for j in -ring...ring where max(abs(i), abs(j)) == ring {
          let p = CGPoint(x: origin.x + Double(i) * step, y: origin.y + Double(j) * step)
          let d = hypot(p.x - origin.x, p.y - origin.y)
          if free(p), best == nil || d < best!.d { best = (p, d) }
        }
      }
      if let best { return CGPoint(x: best.p.x.rounded(), y: best.p.y.rounded()) }
    }
    return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
  }

  // MARK: - Add to Patch (from other tabs)

  /// "Add to Patch" from a Live card, Radio, Spin or the Scope: adds a Live stream node bound
  /// to `stream`, places it, switches to the Patch tab and says so.
  func addStreamSource(_ stream: StreamID, label: String) {
    let x = (graph.nodes.map(\.x).min() ?? 0)
    let y = (graph.nodes.map { $0.y + PatchGeometry.height(of: $0.kind) }.max() ?? -40) + 40
    let id = addNode(.stream, at: CGPoint(x: x, y: y), label: label, stream: stream.rawValue)
    focusRequest = id
    if let app {
      if app.selectedTab != .patch { app.selectedTab = .patch }
      app.showToast("\(label) added to Patch", symbol: "point.3.connected.trianglepath.dotted")
    }
  }

  // MARK: - Modulation matrix hooks (other tabs' knobs)

  /// Lets another tab's knob appear in Knob target pickers as `app.<id>`.
  func registerKnob(id: String, title: String) { registeredKnobs[id] = title }

  /// Knob targets outside the graph, by target key.
  var externalTargets: [(key: String, title: String)] {
    [("app.spectrum.lambda", "Spectrum source A · λ")]
      + registeredKnobs.filter { $0.key != "spectrum.lambda" }.sorted { $0.value < $1.value }
      .map { ("app.\($0.key)", $0.value) }
  }

  /// "Modulate from…" on another tab's knob with a way to set it (`KnobGrid` passes its
  /// binding): while the graph runs, a Knob target aimed at `app.<knobID>` moves that knob in
  /// position space around its value at the moment the drive began, and hands the value back
  /// when the drive or the graph stops (integration).
  func modulate(knobID: String, title: String, scale: KnobScale, get: @escaping () -> Double, set: @escaping (Double) -> Void) {
    externalKnobs[knobID] = ExternalKnob(scale: scale, get: get, set: set)
    modulate(knobID: knobID, title: title)
  }

  /// The dashed modulation arc for a registered knob, around its base value while driven.
  func externalModulation(for knobID: String, spec: KnobSpec) -> KnobModulation? {
    let key = "app.\(knobID)"
    guard let d = snapshot.drives[key], let knob = externalKnobs[knobID] else { return nil }
    let base = externalBase[key] ?? knob.get()
    return KnobModulation(
      value: spec.scale.modulated(base: base, depth: d.depth, cv: d.cv), color: Theme.amber, source: d.source,
      depth: abs(d.depth))
  }

  /// The live drive of another tab's knob (registered with `registerKnob`), for its
  /// `GlassKnob(modulation:)`; nil when nothing drives it.
  func modulation(for knobID: String, spec: KnobSpec, base: Double) -> KnobModulation? {
    guard let d = snapshot.drives["app.\(knobID)"] else { return nil }
    return KnobModulation(
      value: spec.scale.modulated(base: base, depth: d.depth, cv: d.cv), color: Theme.amber, source: d.source, depth: abs(d.depth))
  }

  /// "Modulate from…" on any knob: adds a Knob target aimed at it and opens the Patch tab.
  func modulate(knobID: String, title: String) {
    registerKnob(id: knobID, title: title)
    let p = freeSpot(kind: .knob)
    let id = addNode(.knob, at: p, label: "Drive \(title)")
    setString(id, "target", "app.\(knobID)")
    focusRequest = id
    inspecting = id
    if let app, app.selectedTab != .patch { app.selectedTab = .patch }
  }

  /// "Modulate from…" on a node's own dial: a Knob target aimed at it, placed to its left.
  func modulateParam(_ node: String, _ param: String) {
    guard let n = graph.node(node), let p = n.spec.param(param) else { return }
    // To its left, or the nearest free place there (a card may already sit in that column).
    let left = CGPoint(
      x: (n.x - PatchGeometry.columnPitch + PatchGeometry.cardWidth / 2) * zoom + offset.width,
      y: (n.y + PatchGeometry.height(of: .knob) / 2) * zoom + offset.height)
    let id = addNode(.knob, at: freeSpot(near: left, kind: .knob), label: "Drive \(p.title)")
    setString(id, "target", "\(node).\(param)")
    focusRequest = id
    inspecting = id
  }

  /// Every knob a Knob target may drive: numeric parameters of the other nodes, then the app's.
  func targets(excluding id: String) -> [(key: String, title: String)] {
    var out: [(String, String)] = []
    for n in graph.nodes where n.id != id && n.kind != .knob {
      for p in n.spec.params where p.isModulatable {
        out.append(("\(n.id).\(p.id)", "\(n.title) · \(p.title)"))
      }
    }
    return out + externalTargets
  }

  /// True while a cabled Knob target drives one of this node's dials.
  func isDriven(_ id: String) -> Bool {
    graph.nodes.contains { n in
      n.kind == .knob && n.string("target").hasPrefix(id + ".") && graph.cable(into: PortRef(n.id, "cv")) != nil
    }
  }

  func targetTitle(_ key: String) -> String? {
    if key.isEmpty { return nil }
    if let t = externalTargets.first(where: { $0.key == key }) { return t.title }
    let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2, let n = graph.node(parts[0]), let p = n.spec.param(parts[1]) else { return nil }
    return "\(n.title) · \(p.title)"
  }

  // MARK: - Sensors

  /// The sensor a node reads, if any.
  func sensor(for node: PatchNode) -> SensorID? {
    switch node.kind {
    case .motion, .gyroscope: return .motion
    case .stream: return Self.sensor(forStream: node.string("stream"))
    default: return nil
    }
  }

  /// The sensor behind a scope-bus stream id (API-live §2), nil for simulations: Spin's
  /// `gyro.tip.i/q` is the simulated top, not the gyroscope sensor's `gyro.x/y/z`.
  static func sensor(forStream id: String) -> SensorID? {
    let parts = id.split(separator: ".").map(String.init)
    switch parts.first ?? "" {
    case "mic": return .microphone
    case "mag": return .magnetometer
    case "accel", "gravity", "attitude": return .motion
    case "gyro": return parts.count == 2 && ["x", "y", "z"].contains(parts[1]) ? .motion : nil
    case "baro": return .barometer
    case "ble": return .bluetooth
    case "net": return .network
    case "gnss": return .location
    case "light": return .light
    case "battery", "device": return .charging
    case "uwb": return .uwb
    case "nfc": return .nfc
    default: return nil
    }
  }

  /// True when the node's sensor may start without a tap (no permission, faked, granted before).
  func canAutoStart(_ s: SensorID) -> Bool {
    guard let app else { return false }
    return !s.needsPermission || app.launch.isFaked(s) || startedSensors.contains(s)
      || app.live.channel(s).state.isRunning
  }

  /// The Start button on a node whose sensor needs permission: this tap asks for it.
  func startSensor(_ s: SensorID) {
    startedSensors.insert(s)
    save()
    app?.haptics.tap()
    syncSensors()
  }

  /// Holds exactly the sensors the visible graph reads.
  func syncSensors() {
    guard let app else { return }
    var needed = Set<SensorID>()
    if visible || scopeFeedActive {
      for n in graph.nodes {
        if let s = sensor(for: n), canAutoStart(s) { needed.insert(s) }
      }
    }
    for s in needed.subtracting(acquired) { app.live.acquire(s, by: "patch") }
    for s in acquired.subtracting(needed) { app.live.release(s, by: "patch") }
    acquired = needed
  }

  /// A one-line reason a stream node has nothing yet, and whether a Start button applies.
  func sensorState(for node: PatchNode) -> (sensor: SensorID, state: SensorState, needsTap: Bool)? {
    guard let app, let s = sensor(for: node) else { return nil }
    let state = app.live.channel(s).state
    return (s, state, !canAutoStart(s) && !state.isRunning)
  }

  // MARK: - Running

  /// The tab appeared or disappeared.
  func setVisible(_ v: Bool) {
    guard v != visible else { return }
    visible = v
    syncSensors()
    // Previews pause off screen: bring them up to date on the way back.
    if v { refreshPreviews(force: true) }
    // Leaving for the Scope that "Open in Scope" opened: the Scope feed keeps the graph going.
    if !v, !scopeFeedActive { pause() }
  }

  /// True while the Live tab shows the streams "Open in Scope" sent there.
  private var scopeFeedActive: Bool { feedsScope && app?.selectedTab == .live }

  /// Keeps the graph running off the Patch tab while the Scope shows its streams; ends when
  /// you leave the Live tab for any tab but Patch.
  private func startScopeFeed() {
    feedsScope = true
    guard scopeDriver == nil else { return }
    scopeDriver = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.driveScopeFeed() else { break }
        try? await Task.sleep(for: .milliseconds(11))
      }
      self?.endScopeFeed()
    }
  }

  /// One tick of the Scope feed; false when the feed should end.
  private func driveScopeFeed() -> Bool {
    guard let app, feedsScope else { return false }
    if visible { return true }  // the tab's own loop runs the graph
    guard app.selectedTab == .live else { return false }
    tick(now: SignalClock.now())
    return true
  }

  private func endScopeFeed() {
    feedsScope = false
    scopeDriver = nil
    guard !visible else { return }
    syncSensors()
    pause()
  }

  private func pause() {
    isRunning = false
    runGeneration &+= 1
    scheduler.reset()
    lastTick = nil
    rateWindow = (0, 0)
    if humming {
      app?.haptics.stopHum()
      humming = false
    }
    // A drive acts only while the graph runs: hand Spectrum source A back at its own λ, so a
    // change made on the Spectrum tab meanwhile is not overwritten with a stale base later.
    if let app {
      for (key, base) in externalBase where key == "app.spectrum.lambda" { app.spectrum.tune(lambda: base) }
    }
    for (key, base) in externalBase where key != "app.spectrum.lambda" {
      externalKnobs[String(key.dropFirst("app.".count))]?.set(base)
    }
    externalBase.removeAll()
  }

  /// The run loop while visible: ~90 ticks a second on the main actor.
  func run() async {
    setVisible(true)
    while !Task.isCancelled {
      tick(now: SignalClock.now())
      try? await Task.sleep(for: .milliseconds(11))
    }
    setVisible(false)
  }

  /// One tick: sends the steps that are due (1024-sample blocks for audio-rate graphs, one
  /// frame step otherwise) to the runner and refreshes previews. While the runner is busy the
  /// due blocks wait (up to four are caught up; a longer backlog is dropped).
  func tick(now: Double) {
    guard let app else { return }
    guard app.clock.playing, app.isActive else {
      let wasRunning = isRunning
      if isRunning { pause() }
      // While paused, the transport's Step (+1/60 s) advances the patch by one step too.
      if app.isActive, !wasRunning, let last = lastClockTime, app.clock.time != last { stepOnce() }
      lastClockTime = app.clock.time
      return
    }
    lastClockTime = app.clock.time
    isRunning = true
    if !inFlight {
      var worlds: [GraphInputs] = []
      if graph.isAudioRate {
        lastTick = now
        worlds = scheduler.due(at: now).map(GraphInputs.audioBlock(at:))
      } else {
        scheduler.reset()
        let dt = min(max(now - (lastTick ?? now - 1.0 / 60), 0), 0.1)
        lastTick = now
        if dt > 0 { worlds = [GraphInputs(time: now, dt: dt)] }
      }
      for i in worlds.indices { gatherWorld(&worlds[i], app: app) }
      dispatch(worlds)
    }
    refreshPreviews(now: now)
  }

  /// Runs exactly one step now (Transport ⋯ → Step one block).
  func stepOnce() {
    guard let app else { return }
    let now = SignalClock.now()
    var world = graph.isAudioRate ? GraphInputs.audioBlock(at: scheduler.nextBlockTime ?? now) : GraphInputs(time: now, dt: 1.0 / 60)
    gatherWorld(&world, app: app)
    dispatch([world], force: true)
    app.haptics.tick()
  }

  /// Sends pending edits and `worlds` to the runner (or queues them behind the request in
  /// flight); the reply is carried out on the main actor.
  private func dispatch(_ worlds: [GraphInputs], force: Bool = false) {
    if inFlight {
      if force { queuedWorlds.append(contentsOf: worlds) }
      return
    }
    var request = GraphRequest(reset: pendingReset, load: pendingLoad, worlds: queuedWorlds + worlds)
    pendingReset = false
    pendingLoad = nil
    queuedWorlds = []
    guard request.reset || request.load != nil || !request.worlds.isEmpty else { return }
    if !request.worlds.isEmpty { request.samples = sampleRequests() }
    inFlight = true
    let generation = runGeneration
    let runner = self.runner
    let sent = request
    Task { [weak self] in
      let reply = await runner.run(sent)
      self?.receive(reply, generation: generation)
    }
  }

  private func receive(_ reply: GraphReply, generation: Int) {
    inFlight = false
    snapshot = reply.snapshot
    // An edit queued meanwhile already shows its cables.
    if let g = pendingLoad { snapshot.graph = g }
    guard let app else { return }
    // A reply that left after the graph stopped updates values but plays and drives nothing.
    let live = generation == runGeneration
    for step in reply.steps {
      if live { carryOut(step.effects, app: app, time: step.time) }
      record(step.samples)
      // Every step's tapped values, not just the last step's: a reply that caught up two
      // audio blocks must not leave a 21 ms hole in the Scope's stream.
      publishTaps(app: app, world: GraphInputs(time: step.time, dt: step.dt), values: step.samples)
      if rateWindow.start == 0 {
        // The first step after a start or a pause opens the window (no rate from the pause).
        rateWindow = (step.time, 0)
      } else if step.time - rateWindow.start > 1 {
        stepRate = Double(rateWindow.steps) / max(step.time - rateWindow.start, 1e-3)
        rateWindow = (step.time, 0)
        // Once a second, with the rate: the status chip reads both, and an observed value
        // that moved on every reply re-rendered the whole canvas at the step rate.
        stepMilliseconds = snapshot.averageStepTime * 1000
      }
      rateWindow.steps += 1
    }
    if let last = reply.steps.last {
      if live { applyExternalDrives(app: app, now: last.time) }
      if stepMilliseconds == 0 { stepMilliseconds = snapshot.averageStepTime * 1000 }
    }
    // An edit or a single step shows at once, even while paused.
    if reply.steps.count <= 1, !isRunning { refreshPreviews(force: true) }
    // Edits made meanwhile go now.
    if pendingReset || pendingLoad != nil || !queuedWorlds.isEmpty { dispatch([]) }
  }

  /// Hands an edited graph to the runner (at once when it is idle, else after its request).
  private func queueLoad(_ g: PatchGraph) {
    pendingLoad = g
    activeNodes = GraphEvaluator.activeNodes(in: g)
    // The views resolve cables through the snapshot's graph: follow the edit right away.
    snapshot.graph = g
    dispatch([])
  }

  /// Ports read after every step: each card's rolling trace and the gyroscope trails.
  private func sampleRequests() -> [String: GraphSample] {
    var out: [String: GraphSample] = [:]
    for n in graph.nodes {
      if n.kind == .gyroscope { out["trail.\(n.id)"] = GraphSample(ref: PortRef(n.id, "tip"), viaInput: false) }
      if let (port, _) = historyPort(n) {
        out[n.id] = GraphSample(ref: PortRef(n.id, port), viaInput: n.spec.category == .sinks)
      }
    }
    for ref in taps { out[Self.tapKey(ref)] = GraphSample(ref: ref, viaInput: false) }
    return out
  }

  /// The sample key of an "Open in Scope" tap.
  static func tapKey(_ ref: PortRef) -> String { "tap.\(ref.node).\(ref.port)" }

  // MARK: World

  private func gatherWorld(_ world: inout GraphInputs, app: AppModel) {
    // Spectrum source A (the loop): its wavelength through the stable API every SpectrumModel
    // keeps (`sourceALambda`, API.md §1); E₀ and θ stay at the node's unit plane wave.
    let lambdaA = app.spectrum.sourceALambda
    if lambdaA.isFinite, lambdaA > 0 { world.spectraLambda = lambdaA }
    world.spectraProvenance = [.model]
    // Motion.
    if let p = latest(app, "attitude.pitch"), let y = latest(app, "attitude.yaw"), let r = latest(app, "attitude.roll") {
      let d = Double.pi / 180
      let qz = simd_quatd(angle: y.value * d, axis: SIMD3(0, 0, 1))
      let qx = simd_quatd(angle: p.value * d, axis: SIMD3(1, 0, 0))
      let qy = simd_quatd(angle: r.value * d, axis: SIMD3(0, 1, 0))
      world.attitude = qz * qx * qy
      world.motionProvenance = [p.provenance]
    }
    if let x = latest(app, "gyro.x"), let y = latest(app, "gyro.y"), let z = latest(app, "gyro.z") {
      world.rotationRate = SIMD3(x.value, y.value, z.value)
    }
    for n in graph.nodes where n.kind == .stream && activeNodes.contains(n.id) {
      if let input = streamInput(for: n, world: world, app: app) { world.streams[n.id] = input }
    }
  }

  private func latest(_ app: AppModel, _ id: StreamID) -> (value: Double, provenance: Provenance)? {
    guard let s = app.streams.stream(id), let v = s.ring.latest else { return nil }
    return (Double(v.value), s.provenance)
  }

  /// Resolves "ble.*" to the strongest Bluetooth device (sticky for 5 s).
  private func resolve(_ id: String, node: String, app: AppModel, now: Double) -> SignalStream? {
    guard id == "ble.*" else { return app.streams.stream(StreamID(id)) }
    let candidates = app.streams.streams.filter { $0.id.rawValue.hasPrefix("ble.") && $0.id.rawValue.hasSuffix(".rssi") }
    if let c = cursors[node], let s = candidates.first(where: { $0.id == c.stream }), now - c.chosenAt < 5 { return s }
    return candidates.max { ($0.ring.latest?.value ?? -200) < ($1.ring.latest?.value ?? -200) }
  }

  private func streamInput(for node: PatchNode, world: GraphInputs, app: AppModel) -> StreamInput? {
    let key = node.string("stream")
    guard !key.isEmpty, let stream = resolve(key, node: node.id, app: app, now: world.time) else { return nil }
    var cursor = cursors[node.id] ?? StreamCursor(stream: stream.id, chosenAt: world.time)
    if cursor.stream != stream.id { cursor = StreamCursor(stream: stream.id, chosenAt: world.time) }
    let audioRate = stream.nominalRate >= 8000
    let snap: TimedSamples<Float>
    if let last = cursor.lastTime {
      snap = stream.ring.snapshot(since: last)
    } else {
      snap = audioRate ? stream.ring.snapshot(last: NodeCatalog.blockSize) : stream.ring.snapshot(since: world.time - 0.5)
    }
    if let t = snap.times.last { cursor.lastTime = t }
    var block: RealBlock
    var status: NodeStatus?
    if audioRate && graph.isAudioRate {
      // Exact 1024-sample blocks with one block of latency to ride out jitter.
      cursor.fifo.append(contentsOf: snap.values)
      let n = NodeCatalog.blockSize
      if cursor.fifo.count > 6 * n { cursor.fifo.removeFirst(cursor.fifo.count - 2 * n) }
      if !cursor.primed, cursor.fifo.count >= 2 * n { cursor.primed = true }
      if cursor.primed, cursor.fifo.count >= n {
        block = RealBlock(samples: Array(cursor.fifo.prefix(n)), sampleRate: stream.nominalRate, startTime: world.time, unit: stream.unit)
        cursor.fifo.removeFirst(n)
      } else {
        block = RealBlock(samples: [Float](repeating: 0, count: n), sampleRate: stream.nominalRate, startTime: world.time, unit: stream.unit)
        if cursor.primed { status = NodeStatus("Stream ran dry for a block.", .info) }
        cursor.primed = cursor.primed && cursor.fifo.count >= n
      }
    } else if stream.isIrregular {
      block = RealBlock(samples: snap.values, sampleRate: 0, startTime: snap.times.first ?? world.time, unit: stream.unit, times: snap.times)
    } else {
      // The declared rate, not the jittery measured one: a filter or FFT must not restart
      // every block. Samples keep their own timestamps either way.
      let rate = stream.nominalRate > 0 ? stream.nominalRate : (stream.measuredRate ?? 0)
      block = RealBlock(samples: snap.values, sampleRate: rate, startTime: snap.times.first ?? world.time, unit: stream.unit)
    }
    let iq = quadratureBlock(for: node, stream: stream, cursor: &cursor, world: world, app: app)
    cursors[node.id] = cursor
    var badges = [stream.provenance]
    if Self.isAnalogy(stream) { badges.append(.analogy) }
    return StreamInput(
      block: block, latest: stream.ring.latest.map { Double($0.value) }, provenance: badges, label: stream.label,
      status: status, lambda: stream.lambda, iq: iq)
  }

  /// Rule R2: a stream that is not electromagnetic carries ANALOGY: sound, motion, air, and
  /// Spin's gyroscope rotor (`gyro.tip.*`, non-EM in the Spin group).
  static func isAnalogy(_ stream: SignalStream) -> Bool {
    [StreamGroup.audio, StreamGroup.motion, StreamGroup.air].contains(stream.group)
      || (stream.group == StreamGroup.spin && !stream.isEM)
  }

  /// The stream and its quadrature partner as one I/Q block (only while the node's I/Q output
  /// is cabled): new samples of both rings since the last pair, matched by timestamp.
  private func quadratureBlock(
    for node: PatchNode, stream: SignalStream, cursor: inout StreamCursor, world: GraphInputs, app: AppModel
  ) -> IQBlock? {
    guard !graph.cables(from: PortRef(node.id, "iq")).isEmpty,
      let partnerID = StreamInput.quadraturePartner(of: stream.id.rawValue),
      let partner = app.streams.stream(StreamID(partnerID)), !stream.isIrregular
    else { return nil }
    let since = cursor.iqLastTime ?? (world.time - 0.5)
    let i = stream.ring.snapshot(since: since)
    let q = partner.ring.snapshot(since: since)
    let rate = stream.nominalRate > 0 ? stream.nominalRate : (stream.measuredRate ?? 0)
    guard rate > 0 else { return nil }
    let pairs = StreamInput.pair(i: i.values, iTimes: i.times, q: q.values, qTimes: q.times, tolerance: 0.25 / rate)
    guard let last = pairs.times.last, let first = pairs.times.first else { return nil }
    cursor.iqLastTime = last
    return IQBlock(
      iq: RF.IQBuffer(i: pairs.i, q: pairs.q), sampleRate: rate, startTime: first,
      carrierHz: stream.lambda.map { SpectrumMarker.frequency(forLambda: $0) })
  }

  // MARK: Effects

  private func carryOut(_ effects: [GraphEffect], app: AppModel, time: Double) {
    var humNow = false
    for e in effects {
      // A node deleted while its step was running leaves nothing behind (no orphan streams).
      guard graph.node(e.node) != nil else { continue }
      switch e {
      case .play(let node, let samples, let rate, let level):
        guard app.settings.soundOn else { continue }
        if feedsBackThroughSpeaker(node, app: app) { continue }
        app.synth.pcmGain = level
        app.synth.playPCM(samples, sampleRate: rate)
      case .hum(_, let intensity, let sharpness):
        humNow = true
        app.haptics.updateHum(intensity: Float(intensity), sharpness: Float(sharpness))
      case .tap(_, let strength):
        app.haptics.transient(intensity: Float(strength), sharpness: 0.6, minGap: 0.035)
      case .scope(let node, let channel, let block, let label, let provenance, let lambda):
        publish(node: node, channel: channel, block: block, label: label, provenance: provenance, lambda: lambda, app: app)
      case .ruler(let node, let lambda, let label, let provenance):
        rulerValues[node] = (lambda, label, provenance)
        if graph.node(node)?.flag("continuous") == true, time - lastTune > 0.25 {
          lastTune = time
          app.spectrum.tune(lambda: lambda)
        }
      }
    }
    if humming, !humNow { app.haptics.stopHum() }
    humming = humNow
  }

  /// Speaker → microphone feedback guard (gyre-integration §4.4): a live microphone upstream
  /// plays only through headphones or Bluetooth.
  func feedsBackThroughSpeaker(_ node: String, app: AppModel) -> Bool {
    let up = graph.ancestors(of: [node])
    let mic = graph.nodes.contains { up.contains($0.id) && $0.kind == .stream && $0.string("stream").hasPrefix("mic.") }
    return mic && !app.launch.isFaked(.microphone) && !AudioRoute.isPrivateOutput
  }

  private func publish(
    node: String, channel: String, block: RealBlock, label: String, provenance: [Provenance], lambda: Double?, app: AppModel
  ) {
    guard !block.samples.isEmpty else { return }
    let key = "\(node).\(channel)"
    let nominal = block.isIrregular ? 0 : (block.sampleRate < 200 ? block.sampleRate.rounded() : block.sampleRate)
    var stream = scopeStreams[key]
    if let s = stream, s.label != label || (s.nominalRate > 0 && abs(s.nominalRate - nominal) > 0.25 * s.nominalRate) {
      app.streams.unregister(s)
      stream = nil
    }
    if stream == nil {
      // Capacity capped: a 20 MS/s I/Q cable must not reserve 2 s of samples.
      let s = SignalStream(
        id: StreamID("patch.\(key)"), label: label, unit: block.unit, nominalRate: nominal,
        provenance: provenance.contains(.live) ? .live : (provenance.contains(.sim) ? .sim : .model),
        isEM: lambda != nil, lambda: lambda, group: StreamGroup.patch,
        capacity: min(SignalStream.defaultCapacity(rate: nominal), 1 << 18))
      app.streams.register(s)
      scopeStreams[key] = s
      stream = s
    }
    guard let s = stream else { return }
    let last = scopeLast[key] ?? -Double.infinity
    var values: [Float] = []
    var times: [Double] = []
    values.reserveCapacity(block.count)
    times.reserveCapacity(block.count)
    for k in 0..<block.count {
      let t = block.time(of: k)
      if t > last {
        values.append(block.samples[k])
        times.append(t)
      }
    }
    guard let tLast = times.last else { return }
    s.ring.append(contentsOf: values, times: times)
    scopeLast[key] = tLast
  }

  /// The streams a Scope sink publishes (for its embedded `ScopeView(fixedStreams:)`).
  func scopeStreamIDs(for node: String) -> [StreamID] {
    scopeStreams.filter { $0.key.hasPrefix(node + ".") }.map(\.value.id).sorted()
  }

  /// The outputs of a node the Scope can draw (samples, I/Q, controls) and the streams they
  /// become, at most four (an I/Q output is two: I and Q).
  func scopeTaps(for node: PatchNode) -> [(ref: PortRef, ids: [StreamID])] {
    var out: [(ref: PortRef, ids: [StreamID])] = []
    var count = 0
    // Outputs that are producing come first, each group in catalogue order.
    let producing = node.spec.outputs.filter { snapshot.value(at: PortRef(node.id, $0.name)) != nil }
    let ports = producing + node.spec.outputs.filter { p in !producing.contains { $0.name == p.name } }
    for p in ports where count < 4 {
      let ref = PortRef(node.id, p.name)
      let type = snapshot.value(at: ref)?.type ?? graph.outputTypes(ref).first
      let base = "patch.\(node.id).\(p.name)"
      switch type {
      case .audio?, .control?:
        out.append((ref: ref, ids: [StreamID(base)]))
        count += 1
      case .iq?:
        let ids = [StreamID(base), StreamID(base + ".q")].prefix(4 - count)
        out.append((ref: ref, ids: Array(ids)))
        count += ids.count
      default: continue
      }
    }
    return out
  }

  /// Publishes one step's tapped outputs ("Open in Scope" on a node that is not a Scope).
  private func publishTaps(app: AppModel, world: GraphInputs, values: [String: PortValue]) {
    for ref in taps {
      guard let n = graph.node(ref.node), let v = values[Self.tapKey(ref)] else { continue }
      let label = "\(n.title) · \(n.spec.output(ref.port)?.title ?? ref.port)"
      switch v.payload {
      case .audio(let b):
        publish(node: ref.node, channel: ref.port, block: b, label: label, provenance: v.provenance, lambda: nil, app: app)
      case .iq(let b):
        let lambda = b.carrierHz.map { SpectrumMarker.lambda(forFrequency: $0) }
        publish(
          node: ref.node, channel: ref.port,
          block: RealBlock(samples: b.iq.i, sampleRate: b.sampleRate, startTime: b.startTime, unit: "I"), label: label + " I",
          provenance: v.provenance, lambda: lambda, app: app)
        publish(
          node: ref.node, channel: ref.port + ".q",
          block: RealBlock(samples: b.iq.q, sampleRate: b.sampleRate, startTime: b.startTime, unit: "Q"), label: label + " Q",
          provenance: v.provenance, lambda: lambda, app: app)
      case .control(let x):
        publish(
          node: ref.node, channel: ref.port,
          block: RealBlock(samples: [Float(x)], sampleRate: SinkProcessor.controlRate(world), startTime: world.time, unit: ""),
          label: label, provenance: v.provenance, lambda: nil, app: app)
      default: break
      }
    }
  }

  /// "Open in Scope" on any node: a Scope node's channels, a Live stream's own stream, or the
  /// node's outputs published as `patch.<node>.<port>`. The graph keeps running while the Scope
  /// shows them.
  func openInScope(_ node: String) {
    guard let app, let n = graph.node(node) else { return }
    if n.kind == .stream {
      guard let s = resolve(n.string("stream"), node: node, app: app, now: SignalClock.now()) else {
        app.haptics.boundary()
        app.showToast("Pick a running stream first", symbol: "waveform.path.ecg")
        return
      }
      inspecting = nil
      app.openScope([s.id])
      return
    }
    var ids = scopeStreamIDs(for: node)
    if n.kind != .scope {
      let chosen = scopeTaps(for: n)
      for t in chosen where !taps.contains(t.ref) { taps.append(t.ref) }
      ids = chosen.flatMap(\.ids)
    }
    guard !ids.isEmpty else {
      app.haptics.boundary()
      app.showToast(
        n.kind == .scope ? "Cable a signal into CH1–CH4 first" : "Nothing here the Scope can draw", symbol: "waveform.path.ecg")
      return
    }
    inspecting = nil
    startScopeFeed()
    app.openScope(Array(ids.prefix(4)))
  }

  /// Ruler "Send to Spectrum": tunes source A and switches tab.
  func sendRuler(_ node: String) {
    guard let r = rulerValues[node] else {
      app?.haptics.boundary()
      return
    }
    // Close the inspector first: a sheet left open would cover the Spectrum tab it switches to
    // (integration; `openInScope` does the same).
    inspecting = nil
    app?.sendToSpectrum(lambda: r.lambda, label: r.label)
  }

  /// Applies Knob-target drives aimed at other tabs' knobs that Patch can set itself.
  private func applyExternalDrives(app: AppModel, now: Double) {
    let key = "app.spectrum.lambda"
    if let d = snapshot.drives[key] {
      let base = externalBase[key] ?? app.spectrum.sourceALambda
      externalBase[key] = base
      let scale = ParamScale(range: 1e-13...1e8, logarithmic: true)
      if now - lastTune > 0.1 {
        lastTune = now
        app.spectrum.tune(lambda: scale.modulated(base: base, depth: d.depth, cv: d.cv))
      }
    } else if let base = externalBase.removeValue(forKey: key) {
      app.spectrum.tune(lambda: base)
    }
    // Every other registered knob, through the setter its KnobGrid handed over.
    for (id, knob) in externalKnobs {
      let k = "app.\(id)"
      guard k != key else { continue }
      if let d = snapshot.drives[k] {
        let base = externalBase[k] ?? knob.get()
        externalBase[k] = base
        if now - (externalSetTime[k] ?? 0) > 0.1 {
          externalSetTime[k] = now
          knob.set(knob.scale.modulated(base: base, depth: d.depth, cv: d.cv))
        }
      } else if let base = externalBase.removeValue(forKey: k) {
        knob.set(base)
      }
    }
  }

  // MARK: - Previews

  /// Extends the cards' rolling traces with one step's samples (`sampleRequests`).
  private func record(_ samples: [String: PortValue]) {
    for (key, v) in samples {
      if key.hasPrefix("tap.") { continue }
      if key.hasPrefix("trail.") {
        let id = String(key.dropFirst("trail.".count))
        guard let b = v.payload.iqBlock, b.count > 0, recordedBlock[key] != b.startTime else { continue }
        recordedBlock[key] = b.startTime
        // removeValue leaves the array uniquely referenced, so appending does not copy it.
        var t = trails.removeValue(forKey: id) ?? []
        // Two points a step keep about 9 s: a whole precession circle (Ωp ≈ 0.2 Hz at 3,000
        // rpm), not the quarter arc that six points a step and 480 kept.
        let stride = max(1, (b.count + 1) / 2)
        for k in Swift.stride(from: 0, to: b.count, by: stride) { t.append(SIMD2(b.iq.i[k], b.iq.q[k])) }
        if t.count > 1200 { t.removeFirst(t.count - 1200) }
        trails[id] = t
        continue
      }
      var h = histories.removeValue(forKey: key) ?? []
      defer { histories[key] = h }
      switch v.payload {
      case .control(let x):
        h.append(x)
      case .audio(let b):
        // A held block is not new: draw each block once. Min/max pairs keep its peaks.
        guard recordedBlock[key] != b.startTime else { continue }
        recordedBlock[key] = b.startTime
        let pairs = max(1, min(8, b.count / 2))
        let span = max(1, b.count / pairs)
        var k = 0
        while k < b.count {
          let slice = b.samples[k..<min(b.count, k + span)]
          if let lo = slice.min(), let hi = slice.max() {
            h.append(Double(lo))
            h.append(Double(hi))
          }
          k += span
        }
      default:
        continue
      }
      if h.count > 240 { h.removeFirst(h.count - 240) }
    }
  }

  /// Which port feeds a node's rolling trace (sinks: an input).
  private func historyPort(_ n: PatchNode) -> (String, Bool)? {
    switch n.kind {
    case .stream: return n.string("stream").hasPrefix("mic.") ? nil : ("value", true)
    case .motion: return ("yaw", true)
    case .envelope: return ("env", true)
    case .antenna: return ("gain", true)
    case .channel: return ("snr", true)
    case .gyroscope: return ("tipX", true)
    case .knob: return ("cv", true)
    case .scope: return ("ch1", true)
    case .haptics: return ("intensity", true)
    case .ruler: return ("in", true)
    case .gain, .filter, .mixer: return ("out", true)
    default: return nil
    }
  }

  func refreshPreviews(now: Double = SignalClock.now(), force: Bool = false) {
    guard force || now - lastPreview >= Self.previewInterval else { return }
    lastPreview = now
    // Off screen (feeding the Scope) only the strip's markers need to follow the graph.
    guard visible || force else {
      updateLiveMarkers()
      return
    }
    var next: [String: NodePreview] = [:]
    for n in graph.nodes { next[n.id] = preview(n) }
    previews = next
    statuses = snapshot.statuses
    updateLiveMarkers()
    for n in graph.nodes where n.kind == .spectrum {
      pushWaterfall(n)
    }
    revision &+= 1
  }

  func preview(_ id: String) -> NodePreview { previews[id] ?? NodePreview() }

  /// Publishes running marker values when they move by more than 0.1 % (keeps the strip
  /// current without invalidating it every frame).
  private func updateLiveMarkers() {
    var next: [String: Double] = [:]
    for n in graph.nodes {
      switch n.kind {
      case .spinFID:
        if let f = snapshot.value(at: PortRef(n.id, "larmor"))?.payload.control, f > 0 {
          next[n.id] = SpectrumMarker.lambda(forFrequency: f)
        }
      case .blackbody:
        if let l = snapshot.value(at: PortRef(n.id, "peak"))?.payload.control, l > 0 { next[n.id] = l }
      case .ruler:
        if let r = rulerValues[n.id] { next[n.id] = r.lambda }
      case .modulator where graph.cable(into: PortRef(n.id, "carrier")) != nil:
        if let f = snapshot.value(at: PortRef(n.id, "signal"))?.payload.iqBlock?.carrierHz, f > 0 {
          next[n.id] = SpectrumMarker.lambda(forFrequency: f)
        }
      default: break
      }
    }
    let changed =
      next.count != liveMarkers.count
      || next.contains { k, v in
        guard let old = liveMarkers[k] else { return true }
        return abs(v - old) > 1e-3 * abs(old)
      }
    if changed { liveMarkers = next }
  }

  /// The rolling trace behind a node's preview (control values over the last few seconds).
  func histories(_ id: String) -> [Double] { histories[id] ?? [] }

  /// A Gyroscope tip's recent path seen from above (about 10 s), oldest first.
  func trail(_ id: String) -> [SIMD2<Float>] { trails[id] ?? [] }

  /// The unit of the stream a Live stream node is reading ("µT", "dBm"), "" when none yet.
  func streamUnit(_ id: String) -> String {
    cursors[id].flatMap { app?.streams.stream($0.stream)?.unit } ?? ""
  }

  /// The status line a card shows (the model adds sensor and sound reasons).
  func status(_ id: String) -> NodeStatus? {
    guard let n = graph.node(id), let app else { return statuses[id] }
    if let s = sensorState(for: n), !s.state.isRunning {
      switch s.state {
      case .denied: return NodeStatus("\(s.sensor.title) access is off.", .warning)
      case .unavailable(let why), .locked(let why): return NodeStatus(why, .warning)
      case .requesting: return NodeStatus("Asking for \(s.sensor.title)…", .waiting)
      default:
        if s.needsTap { return NodeStatus("Tap Start to use the \(s.sensor.title).", .waiting) }
      }
    }
    if n.kind == .speaker {
      if !app.settings.soundOn { return NodeStatus("Sound is off in Settings.", .waiting) }
      if feedsBackThroughSpeaker(id, app: app) {
        return NodeStatus("Muted: the speaker would feed the microphone. Use headphones.", .warning)
      }
    }
    if n.kind == .haptics, !app.settings.continuousHum, graph.cable(into: PortRef(id, "intensity")) != nil {
      return NodeStatus("Continuous hum is off in Settings; events still tap.", .info)
    }
    if !isRunning, !(app.clock.playing) { return statuses[id] ?? NodeStatus("Paused.", .info) }
    return statuses[id]
  }

  private func pushWaterfall(_ n: PatchNode) {
    guard let f = snapshot.value(into: PortRef(n.id, "in"))?.payload.spectrum else { return }
    // One row per new spectrum: a forced refresh (an edit, a knob turn, a pause) is not one.
    guard waterfallFrames[n.id] != f else { return }
    waterfallFrames[n.id] = f
    let floor = n.number("floor")
    let buffer = waterfalls[n.id] ?? WaterfallBuffer(width: 192, height: 96, dbRange: floor...(floor + 120))
    // The Floor dial moves the waterfall's colour scale too.
    if buffer.dbRange.lowerBound != floor { buffer.dbRange = floor...(floor + 120) }
    waterfalls[n.id] = buffer
    let db = f.decibels
    guard db.count > 1 else { return }
    let width = 192
    var row = [Float](repeating: Float(floor), count: width)
    for x in 0..<width {
      let lo = x * db.count / width
      let hi = max(lo + 1, (x + 1) * db.count / width)
      row[x] = db[lo..<min(hi, db.count)].max() ?? Float(floor)
    }
    buffer.push(row)
  }

  /// Tint of a value: band colour for EM and carriers, phosphor for samples, amber for control.
  static func tint(of v: PortValue?) -> PatchTint {
    guard let v else { return .idle }
    switch v.payload {
    case .em(let w): return .band(w.lambda)
    case .iq(let b):
      if let f = b.carrierHz, f > 0 { return .band(SpectrumMarker.lambda(forFrequency: f)) }
      return .phosphor
    case .spectrum(let s):
      if let f = s.carrierHz, f > 0 { return .band(SpectrumMarker.lambda(forFrequency: f)) }
      return .phosphor
    case .audio, .image: return .phosphor
    case .control, .event, .attitude, .bits: return .amber
    }
  }

  /// The tint of a cable (from its source port's latest value).
  func tint(of cable: PatchCable) -> PatchTint { Self.tint(of: snapshot.value(at: cable.from)) }

  private func preview(_ n: PatchNode) -> NodePreview {
    var p = NodePreview()
    let out = { (port: String) in self.snapshot.value(at: PortRef(n.id, port)) }
    let into = { (port: String) in self.snapshot.value(into: PortRef(n.id, port)) }
    let history = histories[n.id] ?? []
    func use(_ v: PortValue?) {
      p.tint = Self.tint(of: v)
      p.provenance = v?.provenance ?? p.provenance
    }
    switch n.kind {
    case .spectraSource, .medium, .blackbody:
      let v = out("wave")
      use(v)
      if let w = v?.payload.em {
        p.plot = .swatch(lambda: w.lambda)
        p.value = SpectraFormat.wavelength(w.lambda)
        if n.kind == .medium, let t = out("transmission")?.payload.control { p.value = "T \(SpectraFormat.significant(t, 3))" }
      }
    case .oscillator, .noise, .mixer, .filter:
      let v = out("out")
      use(v)
      if let b = v?.payload.audio, b.count < 64 {
        // A slow sensor arrives a few samples a step: show its recent history instead.
        p.plot = .trace(history, steps: b.isIrregular)
      } else if let b = v?.payload.audio {
        p.plot = .trace(Self.decimate(b.samples, to: 120), steps: false)
      } else if let b = v?.payload.iqBlock {
        p.plot = .trace(Self.decimate(b.iq.i, to: 120), steps: false)
      }
      if n.kind == .oscillator { p.value = SpectraFormat.frequency(n.number("f")) }
      if n.kind == .filter { p.value = SpectraFormat.frequency(n.number("f")) }
      if n.kind == .mixer, graph.cable(into: PortRef(n.id, "b")) == nil { p.value = "LO \(SpectraFormat.frequency(n.number("lo")))" }
    case .gain:
      let v = out("out")
      use(v)
      if case .control(let x)? = v?.payload {
        p.plot = .trace(history, steps: false)
        p.value = SpectraFormat.significant(x, 3)
      } else if let b = v?.payload.audio {
        p.plot = .trace(b.count < 64 ? history : Self.decimate(b.samples, to: 120), steps: false)
        p.value = SpectraFormat.decibels(n.number("gain"), signed: true)
      } else if let b = v?.payload.iqBlock {
        p.plot = .trace(Self.decimate(b.iq.i, to: 120), steps: false)
        p.value = SpectraFormat.decibels(n.number("gain"), signed: true)
      }
    case .bits:
      let v = out("bits")
      use(v)
      if let b = v?.payload.bits {
        p.plot = .text(b.text ?? b.bits.prefix(48).map { $0 == 0 ? "0" : "1" }.joined())
        p.value = "\(b.bits.count) bits / step"
      }
    case .stream:
      if n.string("stream").hasPrefix("mic.") {
        let v = out("samples")
        use(v)
        if let b = v?.payload.audio { p.plot = .trace(Self.decimate(b.samples, to: 120), steps: false) }
        if let b = v?.payload.audio { p.value = "\(SpectraFormat.significant(20 * log10(max(b.rms, 1e-6)), 3)) dBFS" }
      } else {
        let v = out("value")
        use(v)
        p.plot = .trace(history, steps: n.string("stream").hasPrefix("ble."))
        if let x = v?.payload.control {
          p.value = "\(SpectraFormat.significant(x, 4)) \(streamUnit(n.id))".trimmingCharacters(in: .whitespaces)
        }
        // An EM stream (BLE RSSI at 2.44 GHz) takes its carrier's band colour.
        if let id = cursors[n.id]?.stream, let lambda = app?.streams.stream(id)?.lambda { p.tint = .band(lambda) }
      }
    case .motion:
      let v = out("attitude")
      use(v)
      p.plot = .trace(history, steps: false)
      if let y = out("yaw")?.payload.control { p.value = String(format: "yaw %.0f°", y) }
    case .gyroscope:
      let v = out("tip")
      use(out("precession"))
      if let trail = trails[n.id], trail.count > 1 {
        let r = max(0.05, (trail.map { max(abs($0.x), abs($0.y)) }.max() ?? 0.3) * 1.15)
        p.plot = .points(trail, ideal: [], range: r)
      } else if let b = v?.payload.iqBlock {
        p.plot = .points(Array(b.iq.points.suffix(240)), ideal: [], range: 0.5)
      } else {
        p.plot = .trace(history, steps: false)
      }
      if let f = out("precession")?.payload.control { p.value = "Ωp \(SpectraFormat.frequency(abs(f)))" }
    case .spinFID:
      let v = out("audio")
      use(out("larmor"))
      p.tint = Self.tint(of: v)
      if let b = v?.payload.audio { p.plot = .trace(Self.decimate(b.samples, to: 120), steps: false) }
      if let f = out("larmor")?.payload.control {
        p.value = "fL \(SpectraFormat.frequency(f))"
        p.tint = .band(SpectrumMarker.lambda(forFrequency: f))
      }
    case .modulator:
      let v = out("signal")
      use(v)
      // The in-phase component: AM's envelope, FM's swinging phasor, a digital waveform.
      if let b = v?.payload.iqBlock {
        p.plot = .trace(Self.decimate(b.iq.i, to: 120), steps: false)
      }
      let mode = n.spec.param("mode")?.options.first { $0.key == n.string("mode") }?.title ?? n.string("mode")
      p.value = "\(mode) · \(SpectraFormat.frequency(v?.payload.iqBlock?.carrierHz ?? n.number("carrier")))"
    case .demodulator:
      let sym = out("symbols")
      let audio = out("audio")
      if let b = sym?.payload.iqBlock {
        use(sym)
        p.plot = .points(Array(b.iq.points.suffix(600)), ideal: b.ideal, range: 1.5)
      } else if let b = audio?.payload.audio {
        use(audio)
        p.plot = .trace(Self.decimate(b.samples, to: 120), steps: false)
      } else if let b = out("bits")?.payload.bits, let t = b.text {
        use(out("bits"))
        p.plot = .text(t)
      }
      if let ber = out("ber")?.payload.control {
        p.value = "BER \(ber == 0 ? "0" : SpectraFormat.scientific(ber, digits: 2))"
        if let e = out("evm")?.payload.control { p.value! += String(format: " · EVM %.1f %%", e) }
      } else if audio != nil {
        p.value = "Audio out"
      }
    case .envelope:
      use(out("env"))
      p.plot = .trace(history, steps: false)
      if let e = out("env")?.payload.control { p.value = String(format: "%.2f", e) }
    case .antenna:
      use(out("signal") ?? out("gain"))
      p.plot = .trace(history, steps: false)
      if let g = out("gain")?.payload.control { p.value = String(format: "%.1f dBi", g) }
      if p.tint == .idle || p.tint == .amber { p.tint = .band(SpectrumMarker.lambda(forFrequency: n.number("frequency"))) }
    case .channel:
      let v = out("signal")
      use(v)
      if let b = v?.payload.iqBlock {
        p.plot = .trace(Self.decimate(b.iq.i, to: 120), steps: false)
      } else {
        p.plot = .trace(history, steps: false)
      }
      if let s = out("snr")?.payload.control, let r = out("rxPower")?.payload.control {
        p.value = String(format: "SNR %.1f dB · %.0f dBm", s, r)
      }
    case .fft:
      let v = out("spectrum")
      use(v)
      if let s = v?.payload.spectrum {
        p.plot = .spectrum(Self.decimateMax(s.decibels, to: 96).map(Double.init), floor: -120)
        p.value = Self.peakText(s)
      }
    case .wigner:
      let v = out("image")
      use(v)
      if let img = v?.payload.image {
        p.plot = .image(Self.downsample(img.image.plane.signedUnit(), rows: img.image.plane.rows, columns: img.image.plane.columns, side: 32), side: 32)
        p.value = img.mode.title
      }
    case .marginal:
      let v = out("frequency")
      use(v)
      if let s = v?.payload.spectrum { p.plot = .spectrum(Self.decimateMax(s.decibels, to: 96).map(Double.init), floor: -120) }
      if let e = out("error")?.payload.control { p.value = "M1 error \(SpectraFormat.scientific(max(e, 1e-18), digits: 1))" }
    case .scope:
      let v = into("ch1")
      use(v)
      if let b = v?.payload.audio, b.count >= 64 {
        p.plot = .trace(Self.decimate(b.samples, to: 120), steps: false)
      } else if let b = v?.payload.iqBlock {
        p.plot = .trace(Self.decimate(b.iq.i, to: 120), steps: false)
      } else {
        p.plot = .trace(history, steps: false)
      }
      p.provenance = Provenance.union(["ch1", "ch2", "ch3", "ch4"].compactMap { into($0)?.provenance })
      let n = ["ch1", "ch2", "ch3", "ch4"].filter { graph.cable(into: PortRef(n.id, $0)) != nil }.count
      p.value = n == 0 ? nil : "\(n) channel\(n == 1 ? "" : "s") on the bus"
    case .spectrum:
      let v = into("in")
      use(v)
      if let s = v?.payload.spectrum {
        p.plot = .spectrum(Self.decimateMax(s.decibels, to: 96).map(Double.init), floor: n.number("floor"))
        p.value = Self.peakText(s)
      } else if let img = v?.payload.image {
        p.plot = .image(Self.downsample(img.image.plane.signedUnit(), rows: img.image.plane.rows, columns: img.image.plane.columns, side: 32), side: 32)
        p.value = img.mode.title
      }
    case .constellation:
      let v = into("in")
      use(v)
      if let b = v?.payload.iqBlock {
        p.plot = .points(Array(b.iq.points.suffix(800)), ideal: b.ideal, range: Float(n.number("range")))
        p.value = b.modulation?.displayName
      }
    case .speaker:
      let v = into("in")
      use(v)
      if let b = v?.payload.audio {
        p.plot = .level(min(1, b.rms * 3))
        p.value = "\(SpectraFormat.significant(20 * log10(max(b.rms, 1e-6)), 3)) dBFS"
      }
    case .haptics:
      let v = into("intensity")
      use(v ?? into("events"))
      if let x = v?.payload.control {
        p.plot = .level(min(1, max(0, x * n.number("gain"))))
      } else if let b = v?.payload.audio {
        p.plot = .level(min(1, b.rms * 2.0.squareRoot() * n.number("gain")))
      }
    case .ruler:
      if let r = rulerValues[n.id] {
        p.plot = .swatch(lambda: r.lambda)
        p.value = "\(SpectraFormat.wavelength(r.lambda)) · \(SpectraFormat.frequency(SpectrumMarker.frequency(forLambda: r.lambda)))"
        p.tint = .band(r.lambda)
        p.provenance = r.provenance
      }
    case .knob:
      let v = into("cv")
      use(v)
      p.plot = .trace(history, steps: false)
      p.value = targetTitle(n.string("target"))
    }
    return p
  }

  /// "peak 2.13 kHz", or for an I/Q spectrum the offset from its carrier ("peak fc − 1.2 kHz").
  static func peakText(_ s: SpectrumFrame) -> String? {
    guard let f = s.peakHz else { return nil }
    guard s.startFrequency < 0 else { return "peak \(SpectraFormat.frequency(abs(f)))" }
    if abs(f) < s.binWidth { return "peak at the carrier" }
    return "peak fc \(f < 0 ? "−" : "+") \(SpectraFormat.frequency(abs(f)))"
  }

  static func decimate(_ x: [Float], to n: Int) -> [Double] {
    guard x.count > n, n > 1 else { return x.map(Double.init) }
    return (0..<n).map { Double(x[$0 * (x.count - 1) / (n - 1)]) }
  }

  static func decimateMax(_ x: [Float], to n: Int) -> [Float] {
    guard x.count > n, n > 0 else { return x }
    return (0..<n).map { k in
      let lo = k * x.count / n
      let hi = max(lo + 1, (k + 1) * x.count / n)
      return x[lo..<min(hi, x.count)].max() ?? 0
    }
  }

  /// Box-averages a rows × columns image down to side × side.
  static func downsample(_ v: [Float], rows: Int, columns: Int, side: Int) -> [Float] {
    guard rows > 0, columns > 0, v.count == rows * columns else { return [] }
    var out = [Float](repeating: 0, count: side * side)
    for r in 0..<side {
      for c in 0..<side {
        let r0 = r * rows / side, r1 = max(r0 + 1, (r + 1) * rows / side)
        let c0 = c * columns / side, c1 = max(c0 + 1, (c + 1) * columns / side)
        var s: Float = 0
        var big: Float = 0
        for i in r0..<r1 {
          for j in c0..<c1 {
            let x = v[i * columns + j]
            s += x
            if abs(x) > abs(big) { big = x }
          }
        }
        // Keep the sign structure: mix the mean with the strongest sample.
        out[r * side + c] = 0.5 * s / Float((r1 - r0) * (c1 - c0)) + 0.5 * big
      }
    }
    return out
  }
}

/// A Live stream node's read position in its ring.
struct StreamCursor {
  var stream: StreamID
  var chosenAt: Double
  var lastTime: Double?
  var fifo: [Float] = []
  var primed = false
  /// Time of the last I/Q pair read (the quadrature output keeps its own place).
  var iqLastTime: Double?

  init(stream: StreamID, chosenAt: Double) {
    self.stream = stream
    self.chosenAt = chosenAt
  }
}
