import Foundation

/// The five tabs. Raw values are stable: they appear in persisted JSON, accessibility
/// identifiers (`tab-<rawValue>`) and the `-open <tab>` launch argument.
nonisolated enum AppTab: String, CaseIterable, Codable, Sendable, Identifiable {
  case spectrum, radio, live, spin, patch

  var id: String { rawValue }

  /// One-word tab label.
  var title: String {
    switch self {
    case .spectrum: "Spectrum"
    case .radio: "Radio"
    case .live: "Live"
    case .spin: "Spin"
    case .patch: "Patch"
    }
  }

  /// SF Symbol, each verified in CoreGlyphs `name_availability.plist`.
  var symbol: String {
    switch self {
    case .spectrum: "waveform"
    case .radio: "antenna.radiowaves.left.and.right"
    case .live: "dot.radiowaves.left.and.right"
    case .spin: "gyroscope"
    case .patch: "point.3.connected.trianglepath.dotted"
    }
  }

  /// Identifier of the tab's root content (`tab-root-<rawValue>`), used by UI tests.
  var rootIdentifier: String { "tab-root-\(rawValue)" }

  /// Parses `-open` arguments such as `radio` or `radio/antenna` (case-insensitive).
  init?(argument: String) {
    let head = argument.lowercased().split(separator: "/").first.map(String.init) ?? ""
    guard let tab = AppTab(rawValue: head) else { return nil }
    self = tab
  }
}
