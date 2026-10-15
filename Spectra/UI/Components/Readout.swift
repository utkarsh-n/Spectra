import SwiftUI

/// A labelled value: uppercase caption2 monospaced muted title over a callout monospaced
/// value (amber by default), combined into one accessibility element. Optional badge.
struct Readout: View {
  let title: String
  let value: String
  var color: Color = Theme.amber
  var provenance: Provenance? = nil

  init(_ title: String, value: String, color: Color = Theme.amber, provenance: Provenance? = nil) {
    self.title = title
    self.value = value
    self.color = color
    self.provenance = provenance
  }

  /// Orbitals' original argument labels.
  init(title: String, value: String, color: Color = Theme.amber) {
    self.init(title, value: value, color: color)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(title.instrumentCaps)
          .font(Theme.readoutTitleFont)
          .foregroundStyle(Theme.muted)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
        if let provenance { ProvenanceBadge(provenance, compact: true) }
      }
      Text(value)
        .font(Theme.readoutValueFont)
        .monospacedDigit()
        .foregroundStyle(color)
        .contentTransition(.numericText())
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A grid of readouts that collapses to fewer columns at accessibility type sizes.
struct ReadoutGrid<Content: View>: View {
  var columns = 3
  @ViewBuilder var content: Content
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let count = typeSize.isAccessibilitySize ? 1 : max(1, columns)
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: count),
      alignment: .leading, spacing: 14
    ) { content }
  }
}
