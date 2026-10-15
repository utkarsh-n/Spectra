import Foundation

/// Where a number comes from (coherence rule R4). Every readout, marker, signal stream and
/// graph output carries one or more of these, drawn as a `ProvenanceBadge`.
///
/// Pure value type: compiles in the app (MainActor default isolation) and in the macOS
/// engine harnesses.
nonisolated enum Provenance: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
  /// A published table value (CODATA, a datasheet, a standard).
  case table
  /// Computed from a model in this app.
  case model
  /// Measured by this iPhone right now.
  case live
  /// Deduced from indirect evidence (e.g. charging → "probably Qi").
  case inferred
  /// A simulated sensor (Simulator or a `-fake…` launch argument).
  case sim
  /// The API exists but this signing team cannot use it (NFC, Wi-Fi SSID).
  case locked
  /// Needs a second device (UWB ranging).
  case needsPeer
  /// Not electromagnetic: sound, mechanical motion, the rotor. Drawn in phosphor/amber.
  case analogy

  /// Badge text, uppercase as drawn.
  var badge: String {
    switch self {
    case .table: "TABLE"
    case .model: "MODEL"
    case .live: "LIVE"
    case .inferred: "INFERRED"
    case .sim: "SIM"
    case .locked: "LOCKED"
    case .needsPeer: "NEEDS PEER"
    case .analogy: "ANALOGY"
    }
  }

  /// One plain sentence for VoiceOver hints and field notes.
  var meaning: String {
    switch self {
    case .table: "A published reference value."
    case .model: "Calculated by a model in Spectra."
    case .live: "Measured by this iPhone right now."
    case .inferred: "Deduced from indirect evidence, not measured directly."
    case .sim: "Simulated: the sensor is not available here, so Spectra makes up realistic data."
    case .locked: "Locked: this signing team cannot use the API, so Spectra shows the model."
    case .needsPeer: "Needs a second device to measure."
    case .analogy: "Not electromagnetic. Shown as an analogy."
    }
  }

  /// Display order of badges (the order of `allCases`).
  static func < (lhs: Provenance, rhs: Provenance) -> Bool {
    lhs.order < rhs.order
  }

  private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

  /// The union of several provenance lists, deduplicated, in badge order. A graph output
  /// carries the union of its inputs' badges plus its own.
  static func union<S: Sequence>(_ lists: S) -> [Provenance] where S.Element: Sequence, S.Element.Element == Provenance {
    var seen = Set<Provenance>()
    for list in lists { seen.formUnion(list) }
    return seen.sorted()
  }

  /// The union of individual badges, deduplicated, in badge order.
  static func union(_ items: Provenance...) -> [Provenance] {
    Set(items).sorted()
  }

  /// A list deduplicated into badge order.
  static func union(_ items: [Provenance]) -> [Provenance] {
    Set(items).sorted()
  }
}
