import SwiftUI

extension Provenance {
  /// Badge hue. Badges are labels, not data, so they stay small and outlined.
  var color: Color {
    switch self {
    case .table: Theme.amber
    case .model: Theme.iceRGB.color
    case .live: Theme.phosphor
    case .inferred: Theme.violetRGB.color
    case .sim: Color(hex: 0xFF9F43)
    case .locked: Theme.muted
    case .needsPeer: Theme.roseRGB.color
    case .analogy: Theme.mintRGB.color
    }
  }

  var symbol: String {
    switch self {
    case .table: "list.bullet.rectangle"
    case .model: "function"
    case .live: "dot.radiowaves.left.and.right"
    case .inferred: "questionmark.circle"
    case .sim: "cpu"
    case .locked: "lock.fill"
    case .needsPeer: "person.2.fill"
    case .analogy: "waveform"
    }
  }
}

/// A small outlined capsule: "LIVE", "MODEL", "NEEDS PEER" (rule R4: provenance on every
/// number). `compact` drops the padding for use inside readouts.
struct ProvenanceBadge: View {
  let provenance: Provenance
  var compact = false

  /// 9 pt (8 compact) at the default text size, following Dynamic Type up to 15 pt so badges
  /// stay legible at accessibility sizes without crowding readouts (integration: live-review).
  @ScaledMetric(relativeTo: .caption2) private var scaledSize: CGFloat = 9

  init(_ provenance: Provenance, compact: Bool = false) {
    self.provenance = provenance
    self.compact = compact
  }

  var body: some View {
    Text(provenance.badge)
      .font(.system(size: min(15, scaledSize * (compact ? 8.0 / 9.0 : 1)), weight: .semibold, design: .monospaced))
      .tracking(0.8)
      .foregroundStyle(provenance.color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, compact ? 4 : 6)
      .padding(.vertical, compact ? 1.5 : 2.5)
      .background(provenance.color.opacity(0.1), in: .capsule)
      .overlay { Capsule().strokeBorder(provenance.color.opacity(0.45), lineWidth: 0.75) }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(provenance.badge.capitalized)
      .accessibilityHint(provenance.meaning)
  }
}

/// Several badges in badge order ("MODEL · LIVE"), deduplicated.
struct ProvenanceBadges: View {
  let items: [Provenance]
  var compact = false

  init(_ items: [Provenance], compact: Bool = false) {
    self.items = Provenance.union(items)
    self.compact = compact
  }

  var body: some View {
    HStack(spacing: 4) {
      ForEach(items, id: \.self) { ProvenanceBadge($0, compact: compact) }
    }
    .accessibilityElement(children: .combine)
  }
}
