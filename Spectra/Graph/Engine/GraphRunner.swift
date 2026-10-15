import Foundation

// Runs the evaluator off the main actor (SPEC.md §3.6, review: heavy work off main). The
// main-actor `PatchModel` gathers the world, sends one request at a time, and carries out the
// returned effects; the views read the `GraphSnapshot` that comes back with every reply.

/// What the views read of the evaluator: the latest value on every output, statuses, Knob
/// drives and timing, as of the last reply.
nonisolated struct GraphSnapshot: Sendable {
  /// The graph these values belong to (its cables resolve `value(into:)`).
  var graph = PatchGraph()
  var latest: [PortRef: PortValue] = [:]
  var statuses: [String: NodeStatus] = [:]
  /// Knob drives, keyed by target ("n4.f", "app.spectrum.lambda").
  var drives: [String: KnobDrive] = [:]
  /// The nodes a step runs.
  var active: Set<String> = []
  /// Running average CPU time per step, s.
  var averageStepTime = 0.0
  /// Running average CPU time of each node per step, s.
  var nodeTimes: [String: Double] = [:]

  /// The latest value an output produced.
  func value(at output: PortRef) -> PortValue? { latest[output] }

  /// The latest value on the cable into `input` (what a sink shows).
  func value(into input: PortRef) -> PortValue? {
    guard let c = graph.cable(into: input) else { return nil }
    return latest[c.from]
  }
}

extension GraphEvaluator {
  /// A copy of what the views read.
  nonisolated var snapshot: GraphSnapshot {
    GraphSnapshot(
      graph: graph, latest: latest, statuses: statuses, drives: drives, active: active, averageStepTime: averageStepTime,
      nodeTimes: nodeTimes)
  }
}

/// A port sampled after every step (the rolling traces on the cards).
nonisolated struct GraphSample: Sendable, Hashable {
  var ref: PortRef
  /// True: the value on the cable into `ref` (a sink's input); false: `ref`'s own output.
  var viaInput: Bool
}

/// One round trip to the runner: an edit to load first, then the steps to run.
nonisolated struct GraphRequest: Sendable {
  /// Forget every node's state (phases, filters, receivers) before loading.
  var reset = false
  /// The edited graph, loaded before stepping (nodes that keep id and kind keep their state).
  var load: PatchGraph?
  /// Steps to run, oldest first (two audio blocks after a long frame).
  var worlds: [GraphInputs] = []
  /// Ports read after every step, by key.
  var samples: [String: GraphSample] = [:]
}

/// What one step did, for the main actor to carry out.
nonisolated struct GraphStepOutput: Sendable {
  var time: Double
  var dt: Double
  var effects: [GraphEffect]
  /// The requested samples after this step.
  var samples: [String: PortValue]
}

nonisolated struct GraphReply: Sendable {
  var steps: [GraphStepOutput] = []
  var snapshot: GraphSnapshot
}

/// Owns the evaluator and steps it on its own executor. The model keeps at most one request
/// in flight, so loads and steps arrive in order.
actor GraphRunner {
  private var evaluator: GraphEvaluator

  init(graph: PatchGraph) {
    evaluator = GraphEvaluator(graph: graph)
  }

  func run(_ request: GraphRequest) -> GraphReply {
    if request.reset { evaluator.reset() }
    if let g = request.load { evaluator.load(g) }
    var steps: [GraphStepOutput] = []
    steps.reserveCapacity(request.worlds.count)
    for world in request.worlds {
      let r = evaluator.step(world)
      var samples: [String: PortValue] = [:]
      for (key, s) in request.samples {
        if let v = s.viaInput ? evaluator.value(into: s.ref) : evaluator.value(at: s.ref) { samples[key] = v }
      }
      steps.append(GraphStepOutput(time: world.time, dt: world.dt, effects: r.effects, samples: samples))
    }
    return GraphReply(steps: steps, snapshot: evaluator.snapshot)
  }
}
