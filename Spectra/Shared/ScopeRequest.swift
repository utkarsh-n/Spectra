import Foundation

/// A request to show signal streams in the Scope (Live tab → Scope page, or a Patch Scope sink).
/// Made by `AppModel.openScope(_:preset:)` from any card, node or instrument ("Open in Scope").
nonisolated struct ScopeRequest: Equatable, Sendable, Identifiable {
  let id: UUID
  /// Streams for CH1…CH4, in order (extra ids are ignored by a 4-channel scope).
  var streams: [StreamID]
  /// Optional probe preset name the scope should apply (e.g. "Magnetic scope"), or nil.
  var preset: String?

  init(streams: [StreamID], preset: String? = nil, id: UUID = UUID()) {
    self.streams = streams
    self.preset = preset
    self.id = id
  }
}
