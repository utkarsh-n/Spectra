import Foundation
import simd

// The pull evaluator (SPEC.md §3.6): every step runs the nodes in topological order, hands
// each node the values on its input cables, and collects its outputs with the union of the
// inputs' provenance. Audio-rate graphs step in 1024-sample blocks at 48 kHz; the rest step
// once per frame. Pure and `Sendable`: the main-actor `PatchModel` gathers the world
// (streams, attitude, Spectrum source A) into `GraphInputs`, calls `step`, and carries out
// the returned `GraphEffect`s (speaker, haptics, scope streams, the Spectrum ruler).

/// One sensor or simulation stream as a Live stream node sees it this step.
nonisolated struct StreamInput: Sendable, Hashable {
  /// The new samples since the last step (native rate; 48 kHz streams in exact blocks).
  var block: RealBlock
  /// The newest value (sample-and-hold for irregular streams).
  var latest: Double?
  /// The stream's badges (LIVE or SIM, plus ANALOGY for non-EM signals).
  var provenance: [Provenance]
  var label: String
  /// Why the stream is not flowing ("Microphone is off"), if it is not.
  var status: NodeStatus?
  /// Vacuum wavelength of an EM stream's carrier (BLE RSSI: 2.44 GHz).
  var lambda: Double?
  /// The stream and its quadrature partner ("radio.i" + "radio.q", "spin.fid" + "spin.fid.q")
  /// paired by timestamp as one complex envelope, when the partner is on the bus.
  var iq: IQBlock?

  init(
    block: RealBlock, latest: Double? = nil, provenance: [Provenance], label: String, status: NodeStatus? = nil,
    lambda: Double? = nil, iq: IQBlock? = nil
  ) {
    self.block = block
    self.latest = latest ?? block.samples.last.map(Double.init)
    self.provenance = provenance
    self.label = label
    self.status = status
    self.lambda = lambda
    self.iq = iq
  }

  /// The id of a stream's quadrature partner: "x.i" → "x.q", otherwise "x" → "x.q".
  static func quadraturePartner(of id: String) -> String? {
    guard !id.isEmpty, !id.hasSuffix(".q"), !id.hasSuffix("*") else { return nil }
    if id.hasSuffix(".i") { return String(id.dropLast(2)) + ".q" }
    return id + ".q"
  }

  /// Pairs two timestamped series sample by sample (equal times within `tolerance`), oldest
  /// first: the I/Q block of a stream and its partner. Unpaired samples are dropped.
  static func pair(
    i: [Float], iTimes: [Double], q: [Float], qTimes: [Double], tolerance: Double
  ) -> (i: [Float], q: [Float], times: [Double]) {
    var a = 0
    var b = 0
    var oi: [Float] = []
    var oq: [Float] = []
    var ot: [Double] = []
    let n = min(i.count, iTimes.count)
    let m = min(q.count, qTimes.count)
    oi.reserveCapacity(min(n, m))
    oq.reserveCapacity(min(n, m))
    ot.reserveCapacity(min(n, m))
    while a < n, b < m {
      let d = iTimes[a] - qTimes[b]
      if abs(d) <= tolerance {
        oi.append(i[a])
        oq.append(q[b])
        ot.append(iTimes[a])
        a += 1
        b += 1
      } else if d < 0 {
        a += 1
      } else {
        b += 1
      }
    }
    return (oi, oq, ot)
  }
}

/// Everything outside the graph that one step may read.
nonisolated struct GraphInputs: Sendable {
  /// Signal-clock time of the step's first sample, s.
  var time: Double
  /// Seconds the step covers (1024/48 000 for audio-rate graphs, the frame time otherwise).
  var dt: Double
  /// Samples audio-rate sources produce this step (`NodeCatalog.blockSize` in audio-rate
  /// graphs; dt·48 kHz rounded otherwise).
  var audioCount: Int
  /// Live stream nodes' inputs, keyed by node id.
  var streams: [String: StreamInput] = [:]
  /// Device attitude (local → world).
  var attitude: simd_quatd?
  /// Device rotation rate in the device frame, rad/s.
  var rotationRate: SIMD3<Double>?
  var motionProvenance: [Provenance] = [.sim]
  /// Spectrum source A (the loop): vacuum λ (m), and E₀ (V/m) and θ (°) when the host knows
  /// them (nil: a following Spectra source keeps its own amplitude and polarization dials).
  var spectraLambda: Double = 550e-9
  var spectraE0: Double?
  var spectraTheta: Double?
  var spectraProvenance: [Provenance] = [.model]
  /// Seed for noise and random bits.
  var seed: UInt64 = 7

  init(time: Double, dt: Double, audioCount: Int? = nil) {
    self.time = time
    self.dt = dt.isFinite ? max(0, dt) : 0
    self.audioCount = audioCount ?? max(0, Int((self.dt * NodeCatalog.audioRate).rounded()))
  }

  /// One 1024-sample block at 48 kHz starting at `time`.
  static func audioBlock(at time: Double) -> GraphInputs {
    GraphInputs(time: time, dt: Double(NodeCatalog.blockSize) / NodeCatalog.audioRate, audioCount: NodeCatalog.blockSize)
  }
}

/// A side effect a sink asks the main actor to carry out.
nonisolated enum GraphEffect: Sendable, Hashable {
  /// Play mono audio through the synth (Speaker).
  case play(node: String, samples: [Float], sampleRate: Double, level: Double)
  /// Continuous haptic hum (Haptics sink), 0…1.
  case hum(node: String, intensity: Double, sharpness: Double)
  /// One transient per event (Haptics sink).
  case tap(node: String, strength: Double)
  /// Publish samples on a Scope channel stream ("patch.<node>.<channel>").
  case scope(node: String, channel: String, block: RealBlock, label: String, provenance: [Provenance], lambda: Double?)
  /// The Spectrum ruler's value (vacuum λ, m).
  case ruler(node: String, lambda: Double, label: String, provenance: [Provenance])
}

extension GraphEffect {
  /// The sink node that asked for it.
  nonisolated var node: String {
    switch self {
    case .play(let n, _, _, _), .hum(let n, _, _), .tap(let n, _), .scope(let n, _, _, _, _, _), .ruler(let n, _, _, _): n
    }
  }
}

/// A Knob target's live drive of one knob (gyre-integration §7).
nonisolated struct KnobDrive: Sendable, Hashable {
  /// The control value, clamped to −1…1.
  var cv: Double
  /// −1…1: how far a full-scale signal moves the knob, in knob position.
  var depth: Double
  /// The Knob target node that drives it.
  var node: String
  /// The upstream source's title ("Microphone").
  var source: String
  /// The cable's badges.
  var provenance: [Provenance]
}

/// What one step did.
nonisolated struct StepResult: Sendable {
  var effects: [GraphEffect] = []
  /// Nodes that ran (sinks' ancestors; every node when nothing is a sink).
  var evaluated: Int = 0
  /// CPU seconds the step took.
  var duration: Double = 0
}

/// The state a node keeps between steps.
nonisolated protocol NodeProcessor: Sendable {
  mutating func process(_ ctx: inout NodeContext)
}

/// One node's view of a step: its parameters (with Knob-target modulation applied), its
/// inputs, the world, and where it writes outputs, status and effects.
nonisolated struct NodeContext: Sendable {
  let node: PatchNode
  let inputs: [String: PortValue]
  let world: GraphInputs
  /// Knob drives aimed at this node's parameters, by parameter id.
  let drives: [String: KnobDrive]
  /// Titles of the nodes feeding each input (for "Driven by …").
  let sourceTitles: [String: String]
  /// Whether each output is cabled anywhere (skip work for unwired outputs).
  let wiredOutputs: Set<String>
  /// Inputs that have a cable (whether or not a value arrived this step).
  let cabledInputs: Set<String>

  private(set) var outputs: [String: PortValue] = [:]
  var status: NodeStatus?
  var effects: [GraphEffect] = []
  /// Badges this node adds to every output beyond its catalogue ones (e.g. a medium's TABLE).
  var extraProvenance: [Provenance] = []

  init(
    node: PatchNode, inputs: [String: PortValue], world: GraphInputs, drives: [String: KnobDrive] = [:],
    sourceTitles: [String: String] = [:], wiredOutputs: Set<String> = [], cabledInputs: Set<String>? = nil
  ) {
    self.node = node
    self.inputs = inputs
    self.world = world
    self.drives = drives
    self.sourceTitles = sourceTitles
    self.wiredOutputs = wiredOutputs
    self.cabledInputs = cabledInputs ?? Set(inputs.keys)
  }

  // MARK: Parameters

  /// A numeric parameter, modulated by any Knob target driving it.
  func number(_ id: String) -> Double {
    let base = node.number(id)
    guard let drive = drives[id], let scale = node.spec.param(id)?.scale else { return base }
    return scale.modulated(base: base, depth: drive.depth, cv: drive.cv)
  }

  func string(_ id: String) -> String { node.string(id) }
  func flag(_ id: String) -> Bool { number(id) >= 0.5 }

  // MARK: Inputs

  func input(_ port: String) -> PortValue? { inputs[port] }
  func audio(_ port: String) -> RealBlock? { inputs[port]?.payload.audio }
  func iq(_ port: String) -> IQBlock? { inputs[port]?.payload.iqBlock }
  func control(_ port: String) -> Double? {
    guard let v = inputs[port]?.payload.control, v.isFinite else { return nil }
    return v
  }
  /// Whether a cable plugs into `port` (a value may still be on its way).
  func isConnected(_ port: String) -> Bool { cabledInputs.contains(port) || inputs[port] != nil }
  func isWired(_ output: String) -> Bool { wiredOutputs.contains(output) }

  /// The union of every input's badges.
  var inputProvenance: [Provenance] { Provenance.union(inputs.values.map(\.provenance)) }

  /// Badges of everything this node outputs: its own, its extras, and its inputs'.
  var outputProvenance: [Provenance] {
    Provenance.union([node.spec.provenance, extraProvenance, inputProvenance])
  }

  // MARK: Outputs

  mutating func emit(_ port: String, _ payload: SignalPayload, provenance extra: [Provenance] = []) {
    outputs[port] = PortValue(payload, provenance: outputProvenance + extra)
  }

  mutating func emit(_ port: String, control value: Double, provenance extra: [Provenance] = []) {
    guard value.isFinite else { return }
    emit(port, .control(value), provenance: extra)
  }

  mutating func wait(_ text: String) { status = NodeStatus(text, .waiting) }
  mutating func warn(_ text: String) { status = NodeStatus(text, .warning) }
  mutating func note(_ text: String) { status = NodeStatus(text, .info) }
}

/// The evaluator: a patch, each node's processor state, and the values of the last step.
nonisolated struct GraphEvaluator: Sendable {
  private(set) var graph: PatchGraph
  /// Evaluation order (Kahn), computed when the graph is loaded.
  private(set) var order: [String] = []
  /// The nodes a step runs: every sink's ancestors, or every node when the patch has no sink.
  private(set) var active: Set<String> = []
  private var processors: [String: any NodeProcessor] = [:]
  private var kinds: [String: NodeKind] = [:]
  /// Values flowing this step, by output port (block payloads are consumed once).
  private var values: [PortRef: PortValue] = [:]
  /// The latest value every output has produced (what previews and readouts show).
  private(set) var latest: [PortRef: PortValue] = [:]
  /// Each node's status line from the last step.
  private(set) var statuses: [String: NodeStatus] = [:]
  /// Knob drives from the last step, keyed by target ("n4.f", "app.spectrum.lambda").
  private(set) var drives: [String: KnobDrive] = [:]
  private(set) var steps = 0
  /// Precomputed at `load` so a step does no searching: each node's position in `graph.nodes`,
  /// its cabled inputs (with the source's title) and its outputs that feed anything.
  private var nodeIndex: [String: Int] = [:]
  private var inputLinks: [String: [InputLink]] = [:]
  private var wiredOutputs: [String: Set<String>] = [:]
  /// Running average CPU time per step, s.
  private(set) var averageStepTime = 0.0
  /// Running average time each node takes per step, s (the inspector shows it).
  private(set) var nodeTimes: [String: Double] = [:]

  init(graph: PatchGraph = PatchGraph()) {
    self.graph = graph
    load(graph)
  }

  /// Swaps in an edited graph. Nodes that keep their id and kind keep their state (an
  /// oscillator keeps its phase while you turn its knob); values on removed ports vanish.
  mutating func load(_ next: PatchGraph) {
    // A node whose incoming cables changed no longer shows what its old inputs made.
    for n in next.nodes {
      let before = Set(graph.cables.filter { $0.to.node == n.id })
      let after = Set(next.cables.filter { $0.to.node == n.id })
      if before != after {
        latest = latest.filter { $0.key.node != n.id }
        statuses[n.id] = nil
      }
    }
    graph = next
    order = (try? next.topologicalOrder()) ?? next.nodes.map(\.id)
    active = Self.activeNodes(in: next)
    var keep: [String: any NodeProcessor] = [:]
    var keepKinds: [String: NodeKind] = [:]
    for n in next.nodes {
      if kinds[n.id] == n.kind, let p = processors[n.id] {
        keep[n.id] = p
      } else {
        keep[n.id] = NodeFactory.processor(for: n)
      }
      keepKinds[n.id] = n.kind
    }
    processors = keep
    kinds = keepKinds
    nodeIndex = Dictionary(next.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    var links: [String: [InputLink]] = [:]
    var wired: [String: Set<String>] = [:]
    for n in next.nodes {
      for port in n.spec.inputs {
        guard let c = next.cable(into: PortRef(n.id, port.name)) else { continue }
        let title = nodeIndex[c.from.node].map { next.nodes[$0].title } ?? c.from.node
        links[n.id, default: []].append(InputLink(port: port.name, from: c.from, types: port.types, title: title))
      }
    }
    for c in next.cables { wired[c.from.node, default: []].insert(c.from.port) }
    inputLinks = links
    wiredOutputs = wired
    let ids = Set(next.nodes.map(\.id))
    values = values.filter { ids.contains($0.key.node) && next.node($0.key.node)?.spec.output($0.key.port) != nil }
    latest = latest.filter { ids.contains($0.key.node) && next.node($0.key.node)?.spec.output($0.key.port) != nil }
    statuses = statuses.filter { ids.contains($0.key) }
    drives = drives.filter { k, d in ids.contains(d.node) && (k.hasPrefix("app.") || ids.contains(String(k.split(separator: ".").first ?? ""))) }
  }

  /// The nodes a step runs: every sink's ancestors (every node when there is no sink), plus
  /// any node nobody listens to, so a lone Oscillator still shows its preview: everything that
  /// is not dead weight.
  static func activeNodes(in g: PatchGraph) -> Set<String> {
    let sinks = Set(g.nodes.filter { $0.spec.category == .sinks }.map(\.id))
    var active = sinks.isEmpty ? Set(g.nodes.map(\.id)) : g.ancestors(of: sinks)
    let feeding = Set(g.cables.map(\.from.node))
    for n in g.nodes where !active.contains(n.id) && !feeding.contains(n.id) { active.insert(n.id) }
    return active
  }

  /// Forgets every node's state (phases, filters, receivers) and every value.
  mutating func reset() {
    processors = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, NodeFactory.processor(for: $0)) })
    values = [:]
    latest = [:]
    statuses = [:]
    drives = [:]
    steps = 0
  }

  /// The latest value on the cable into `input` (what a sink shows).
  func value(into input: PortRef) -> PortValue? {
    guard let c = graph.cable(into: input) else { return nil }
    return latest[c.from]
  }

  /// The latest value an output produced.
  func value(at output: PortRef) -> PortValue? { latest[output] }

  /// Runs one step.
  mutating func step(_ world: GraphInputs) -> StepResult {
    let start = DispatchTime.now().uptimeNanoseconds
    var result = StepResult()
    var nextDrives: [String: KnobDrive] = [:]
    // Drives aimed inside the graph, grouped by node.
    var nodeDrives: [String: [String: KnobDrive]] = [:]
    for (target, drive) in drives where !target.hasPrefix("app.") {
      let parts = target.split(separator: ".", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      nodeDrives[parts[0], default: [:]][parts[1]] = drive
    }
    for id in order where active.contains(id) {
      guard let index = nodeIndex[id], var processor = processors[id] else { continue }
      let node = graph.nodes[index]
      var inputs: [String: PortValue] = [:]
      var titles: [String: String] = [:]
      for link in inputLinks[id] ?? [] {
        if let v = values[link.from], link.types.contains(v.type) { inputs[link.port] = v }
        titles[link.port] = link.title
      }
      let wired = wiredOutputs[id] ?? []
      let cabled = Set(titles.keys)
      // A process or sink node whose cables carried nothing this step (a modulator still
      // collecting bits) holds: its status stays and its block outputs are not replayed.
      if node.spec.category != .sources, node.kind != .knob, !cabled.isEmpty, inputs.isEmpty {
        for port in node.spec.outputs {
          let ref = PortRef(id, port.name)
          if let old = values[ref] {
            switch old.payload {
            case .audio, .iq, .bits, .event: values[ref] = nil
            default: break
            }
          }
        }
        continue
      }
      var ctx = NodeContext(
        node: node, inputs: inputs, world: world, drives: nodeDrives[id] ?? [:], sourceTitles: titles, wiredOutputs: wired,
        cabledInputs: cabled)
      let t0 = DispatchTime.now().uptimeNanoseconds
      processor.process(&ctx)
      processors[id] = processor
      let took = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
      nodeTimes[id] = nodeTimes[id].map { $0 * 0.9 + took * 0.1 } ?? took
      for (port, v) in ctx.outputs {
        values[PortRef(id, port)] = v
        latest[PortRef(id, port)] = v
      }
      // Outputs the node did not write this step keep their last value (held previews), except
      // block-valued outputs, which must not replay: drop stale audio/iq/bits/events.
      for port in node.spec.outputs where ctx.outputs[port.name] == nil {
        let ref = PortRef(id, port.name)
        if let old = values[ref] {
          switch old.payload {
          case .audio, .iq, .bits, .event: values[ref] = nil
          default: break
          }
        }
      }
      statuses[id] = ctx.status
      result.effects.append(contentsOf: ctx.effects)
      if node.kind == .knob, let cv = ctx.control("cv") {
        let target = node.string("target")
        if !target.isEmpty {
          nextDrives[target] = KnobDrive(
            cv: min(1, max(-1, cv)), depth: node.number("depth"), node: id, source: titles["cv"] ?? "Patch",
            provenance: inputs["cv"]?.provenance ?? [])
        }
      }
      result.evaluated += 1
    }
    drives = nextDrives
    steps += 1
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
    averageStepTime = steps == 1 ? elapsed : averageStepTime * 0.9 + elapsed * 0.1
    result.duration = elapsed
    return result
  }
}

/// A cable into one input, as a step reads it.
nonisolated struct InputLink: Sendable, Hashable {
  var port: String
  var from: PortRef
  /// Types the input accepts.
  var types: [PortType]
  /// The source node's title (for "Driven by …").
  var title: String
}

/// Decides how many audio blocks are due when the display ticks: 1024 samples at 48 kHz is
/// 21.33 ms, so a 60 Hz display runs 0, 1 or 2 blocks per frame, 46.875 per second on
/// average, never catching up more than `maxPerTick` after a stall.
nonisolated struct BlockScheduler: Sendable, Hashable {
  let blockDuration: Double
  var maxPerTick: Int
  /// Signal time of the next block's first sample.
  private(set) var nextBlockTime: Double?
  private(set) var issued = 0

  init(blockSize: Int = NodeCatalog.blockSize, sampleRate: Double = NodeCatalog.audioRate, maxPerTick: Int = 4) {
    blockDuration = Double(blockSize) / sampleRate
    self.maxPerTick = max(1, maxPerTick)
  }

  /// Start times of the blocks due by `now` (oldest first). The first call only starts the
  /// clock; after a stall longer than `maxPerTick` blocks the backlog is dropped (no
  /// catch-up), so time stays contiguous within a run of blocks.
  mutating func due(at now: Double) -> [Double] {
    guard now.isFinite else { return [] }
    guard let next = nextBlockTime else {
      nextBlockTime = now
      return []
    }
    var out: [Double] = []
    var t = next
    while t + blockDuration <= now, out.count < maxPerTick {
      out.append(t)
      t += blockDuration
    }
    if t + blockDuration <= now {
      // Stalled: skip the backlog rather than burst.
      t = now - blockDuration * 0.5
    }
    nextBlockTime = t
    issued += out.count
    return out
  }

  mutating func reset() {
    nextBlockTime = nil
    issued = 0
  }
}
