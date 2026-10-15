import Foundation

/// One node in a patch: its kind, where it sits on the canvas and its parameter values.
/// Codable for `Spectra.patch.v1`; unknown keys and missing parameters fall back to the
/// catalogue defaults.
nonisolated struct PatchNode: Codable, Sendable, Hashable, Identifiable {
  var id: String
  var kind: NodeKind
  /// A custom title (a stream's label); nil uses the catalogue title.
  var label: String?
  /// Canvas position of the card's top-left corner, points.
  var x: Double
  var y: Double
  /// Numeric parameters and switches (1 = on).
  var numbers: [String: Double]
  /// Choice keys, texts, stream ids and knob targets.
  var strings: [String: String]

  init(id: String, kind: NodeKind, x: Double = 0, y: Double = 0, label: String? = nil) {
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    self.label = label
    numbers = [:]
    strings = [:]
  }

  var spec: NodeSpec { kind.spec }
  var title: String { label ?? spec.title }

  /// A numeric parameter (or switch) with its catalogue default; NaN when unknown.
  func number(_ id: String) -> Double {
    if let v = numbers[id], v.isFinite { return v }
    return spec.param(id)?.defaultNumber ?? .nan
  }

  /// A choice, text, stream or target parameter with its catalogue default.
  func string(_ id: String) -> String {
    strings[id] ?? spec.param(id)?.defaultString ?? ""
  }

  func flag(_ id: String) -> Bool { number(id) >= 0.5 }

  // Codable that tolerates missing dictionaries.
  private enum CodingKeys: String, CodingKey { case id, kind, label, x, y, numbers, strings }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    kind = try c.decode(NodeKind.self, forKey: .kind)
    label = try c.decodeIfPresent(String.self, forKey: .label)
    x = (try? c.decode(Double.self, forKey: .x)) ?? 0
    y = (try? c.decode(Double.self, forKey: .y)) ?? 0
    numbers = (try? c.decode([String: Double].self, forKey: .numbers)) ?? [:]
    strings = (try? c.decode([String: String].self, forKey: .strings)) ?? [:]
  }
}

/// A cable from an output port to an input port. An input takes at most one cable; an
/// output may feed many.
nonisolated struct PatchCable: Codable, Sendable, Hashable, Identifiable {
  var from: PortRef
  var to: PortRef

  init(from: PortRef, to: PortRef) {
    self.from = from
    self.to = to
  }

  var id: String { "\(from.node).\(from.port)>\(to.node).\(to.port)" }
}

/// The patch document: nodes and cables. Every edit keeps it acyclic and well typed.
nonisolated struct PatchGraph: Codable, Sendable, Hashable {
  var nodes: [PatchNode] = []
  var cables: [PatchCable] = []

  init(nodes: [PatchNode] = [], cables: [PatchCable] = []) {
    self.nodes = nodes
    self.cables = cables
  }

  // MARK: Lookup

  func node(_ id: String) -> PatchNode? { nodes.first { $0.id == id } }

  func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }

  /// The cable into an input port, if any.
  func cable(into input: PortRef) -> PatchCable? { cables.first { $0.to == input } }

  /// Cables leaving an output port.
  func cables(from output: PortRef) -> [PatchCable] { cables.filter { $0.from == output } }

  /// A fresh node id ("n1", "n2", …) not used yet.
  func makeID() -> String {
    var k = nodes.count + 1
    let used = Set(nodes.map(\.id))
    while used.contains("n\(k)") { k += 1 }
    return "n\(k)"
  }

  // MARK: Editing

  /// Adds a node of `kind` at (x, y) and returns it.
  @discardableResult
  mutating func add(_ kind: NodeKind, x: Double = 0, y: Double = 0, id: String? = nil) -> PatchNode {
    let node = PatchNode(id: id ?? makeID(), kind: kind, x: x, y: y)
    nodes.append(node)
    return node
  }

  /// Removes a node and every cable touching it.
  mutating func remove(node id: String) {
    nodes.removeAll { $0.id == id }
    cables.removeAll { $0.from.node == id || $0.to.node == id }
    // Knob targets pointing at the removed node lose their target.
    for i in nodes.indices where nodes[i].kind == .knob {
      if nodes[i].string("target").hasPrefix("\(id).") { nodes[i].strings["target"] = "" }
    }
  }

  /// The types an output port can produce right now: a `follows` output takes the resolved
  /// type of the cable into the input it follows (Gain, Filter); the Mixer is I/Q when either
  /// input is.
  func outputTypes(_ ref: PortRef, depth: Int = 0) -> [PortType] {
    guard let node = node(ref.node), let port = node.spec.output(ref.port) else { return [] }
    guard depth < 64 else { return port.types }
    if node.kind == .mixer {
      let a = cable(into: PortRef(node.id, "a")).map { outputTypes($0.from, depth: depth + 1) } ?? []
      let b = cable(into: PortRef(node.id, "b")).map { outputTypes($0.from, depth: depth + 1) } ?? []
      if a == [.iq] || b == [.iq] { return [.iq] }
      if a == [.audio] { return [.audio] }
      return port.types
    }
    if let follows = port.follows, let upstream = cable(into: PortRef(node.id, follows)) {
      let t = outputTypes(upstream.from, depth: depth + 1).filter(port.types.contains)
      return t.isEmpty ? port.types : t
    }
    return port.types
  }

  /// Whether `from` (an output) may be cabled to `to` (an input), and why not.
  func check(from: PortRef, to: PortRef) -> GraphError? {
    guard let a = node(from.node) else { return .unknownNode(from.node) }
    guard let b = node(to.node) else { return .unknownNode(to.node) }
    guard a.spec.output(from.port) != nil else {
      return a.spec.input(from.port) != nil ? .direction : .unknownPort(from)
    }
    guard let inSpec = b.spec.input(to.port) else {
      return b.spec.output(to.port) != nil ? .direction : .unknownPort(to)
    }
    if from.node == to.node { return .selfLoop }
    let produced = outputTypes(from)
    if !produced.contains(where: inSpec.types.contains) {
      return .typeMismatch(from: produced, to: inSpec.types)
    }
    // A cable a → b closes a loop when a is already downstream of b.
    if let path = path(from: to.node, to: from.node) { return .cycle(path) }
    return nil
  }

  /// Connects `from` → `to`, replacing any cable already in that input.
  mutating func connect(from: PortRef, to: PortRef) throws(GraphError) {
    if let error = check(from: from, to: to) { throw error }
    cables.removeAll { $0.to == to }
    cables.append(PatchCable(from: from, to: to))
  }

  /// Removes the cable into `input` (returns it).
  @discardableResult
  mutating func disconnect(input: PortRef) -> PatchCable? {
    guard let i = cables.firstIndex(where: { $0.to == input }) else { return nil }
    return cables.remove(at: i)
  }

  mutating func disconnect(_ cable: PatchCable) {
    cables.removeAll { $0 == cable }
  }

  // MARK: Order

  /// Node ids downstream of `start` following cables, as a path to `target` (nil if none).
  func path(from start: String, to target: String) -> [String]? {
    if start == target { return [start] }
    var previous: [String: String] = [:]
    var queue = [start]
    var seen: Set<String> = [start]
    while !queue.isEmpty {
      let n = queue.removeFirst()
      for c in cables where c.from.node == n && !seen.contains(c.to.node) {
        seen.insert(c.to.node)
        previous[c.to.node] = n
        if c.to.node == target {
          var out = [target]
          var k = target
          while let p = previous[k] {
            out.append(p)
            k = p
          }
          return out.reversed()
        }
        queue.append(c.to.node)
      }
    }
    return nil
  }

  /// Kahn's topological order of every node (sources first; ties keep document order).
  /// Throws `.cycle` with the nodes left over when the cables loop.
  func topologicalOrder() throws(GraphError) -> [String] {
    var indegree: [String: Int] = [:]
    for n in nodes { indegree[n.id] = 0 }
    var outgoing: [String: [String]] = [:]
    for c in cables where indegree[c.from.node] != nil && indegree[c.to.node] != nil {
      indegree[c.to.node, default: 0] += 1
      outgoing[c.from.node, default: []].append(c.to.node)
    }
    var ready = nodes.map(\.id).filter { indegree[$0] == 0 }
    var order: [String] = []
    order.reserveCapacity(nodes.count)
    while !ready.isEmpty {
      let n = ready.removeFirst()
      order.append(n)
      for m in outgoing[n] ?? [] {
        indegree[m, default: 0] -= 1
        if indegree[m] == 0 { ready.append(m) }
      }
    }
    if order.count < nodes.count {
      let left = nodes.map(\.id).filter { !order.contains($0) }
      throw .cycle(left)
    }
    return order
  }

  /// `ids` plus every node upstream of them (what a pull from these sinks evaluates).
  func ancestors(of ids: Set<String>) -> Set<String> {
    var out = ids
    var stack = Array(ids)
    while let n = stack.popLast() {
      for c in cables where c.to.node == n && !out.contains(c.from.node) {
        out.insert(c.from.node)
        stack.append(c.from.node)
      }
    }
    return out
  }

  /// A copy with dangling, ill-typed, duplicate-input and loop-closing cables removed (for
  /// documents decoded from storage).
  func repaired() -> PatchGraph {
    var g = PatchGraph(nodes: nodes, cables: [])
    var seenIDs = Set<String>()
    g.nodes = g.nodes.filter { seenIDs.insert($0.id).inserted }
    for c in cables {
      try? g.connect(from: c.from, to: c.to)
    }
    return g
  }

  /// Whether stepping should run in 1024-sample audio blocks.
  var isAudioRate: Bool {
    nodes.contains { n in
      if n.spec.isAudioRate { return true }
      if n.kind == .stream { return n.string("stream").hasPrefix("mic.") }
      if n.kind == .speaker { return true }
      return false
    }
  }
}
