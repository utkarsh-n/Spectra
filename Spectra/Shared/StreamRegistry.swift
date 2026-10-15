import Foundation
import Observation

/// The universal scope bus: every `SignalStream` in the app, registered by its producer
/// while it runs. `AppModel.streams` is the single instance.
@MainActor @Observable
final class StreamRegistry {
  /// Registered streams, sorted by group order, then id.
  private(set) var streams: [SignalStream] = []

  init() {}

  /// Adds a stream, replacing any registered stream with the same id.
  func register(_ stream: SignalStream) {
    var next = streams.filter { $0.id != stream.id }
    next.append(stream)
    streams = Self.sorted(next)
  }

  /// Adds several streams at once (one observation change).
  func register(_ batch: [SignalStream]) {
    let ids = Set(batch.map(\.id))
    streams = Self.sorted(streams.filter { !ids.contains($0.id) } + batch)
  }

  /// Removes this exact stream instance (a newer stream registered under the same id stays).
  func unregister(_ stream: SignalStream) {
    guard streams.contains(where: { $0 === stream }) else { return }
    streams.removeAll { $0 === stream }
  }

  /// Removes whatever is registered under `id`.
  func unregister(_ id: StreamID) {
    guard streams.contains(where: { $0.id == id }) else { return }
    streams.removeAll { $0.id == id }
  }

  /// Removes every stream whose id starts with `prefix` (e.g. `"ble."`).
  func unregister(prefix: String) {
    guard streams.contains(where: { $0.id.rawValue.hasPrefix(prefix) }) else { return }
    streams.removeAll { $0.id.rawValue.hasPrefix(prefix) }
  }

  func stream(_ id: StreamID) -> SignalStream? {
    streams.first { $0.id == id }
  }

  func streams(in group: String) -> [SignalStream] {
    streams.filter { $0.group == group }
  }

  /// Non-empty groups in `StreamGroup.order` (unknown groups last, alphabetically).
  var groups: [(name: String, streams: [SignalStream])] {
    let names = Set(streams.map(\.group))
    let ordered = StreamGroup.order.filter(names.contains) + names.subtracting(StreamGroup.order).sorted()
    return ordered.map { name in (name, streams.filter { $0.group == name }) }
  }

  private static func sorted(_ list: [SignalStream]) -> [SignalStream] {
    func rank(_ group: String) -> Int { StreamGroup.order.firstIndex(of: group) ?? StreamGroup.order.count }
    return list.sorted { a, b in
      let ra = rank(a.group)
      let rb = rank(b.group)
      if ra != rb { return ra < rb }
      if a.group != b.group { return a.group < b.group }
      return a.id < b.id
    }
  }
}
